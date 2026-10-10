///|
async fn lifecycle_accept(
  backend : @backend.BoardBackend,
  replica : @client.BoardReplica,
  command : @protocol.BoardClientCommand,
) -> Unit {
  let previous = replica.revision()
  let result = backend.handle_command(command)
  assert_true(result.accepted)
  assert_eq(result.command_id, command.command_id)
  assert_eq(result.current_revision, Some(previous + 1L))
  // Results settle correlation only, even before the event is consumed.
  assert_true(replica.apply_frame(CommandResult(result)) is CommandSettled(_))
  assert_eq(replica.revision(), previous)
  let history = backend.event_history()
  let event = history.last().unwrap()
  assert_eq(event.board_revision, previous + 1L)
  assert_true(replica.apply_frame(Event(event)) is Applied)
  assert_eq(replica.revision(), previous + 1L)
}

///|
async test "typed manual lifecycle builders commit every kind and outcome through authoritative events" {
  @async.with_timeout(5000, () => {
    let clock = Ref(100L)
    let backend = @backend.BoardBackend(now_ms=() => clock.val)
    @async.with_task_group(group => {
      backend.attach(group)
      let replica = @client.BoardReplica::empty()
      assert_true(
        replica.apply_snapshot(backend.bootstrap_snapshot().unwrap()) is Applied,
      )
      lifecycle_accept(
        backend,
        replica,
        @client.create_task_command(
          "create",
          0L,
          id="t",
          title="Manual lifecycle",
          description="",
          priority=@client.Normal,
          definition_of_done=[],
          dependencies=[],
        ),
      )
      let kinds : Array[@client.ClientAttemptKind] = [
        @client.Discuss,
        @client.Execute,
        @client.Review,
      ]
      let outcomes : Array[@client.ClientAttemptOutcome] = [
        @client.Succeeded,
        @client.Failed,
        @client.Cancelled,
        @client.Interrupted,
      ]
      for kind in kinds {
        for outcome in outcomes {
          let id = kind.to_wire() + "-" + outcome.to_wire()
          clock.val = clock.val + 10L
          let queued_at = clock.val
          lifecycle_accept(
            backend,
            replica,
            @client.queue_attempt_command(
              "queue-" + id,
              replica.revision(),
              id~,
              task_id="t",
              kind~,
            ),
          )
          assert_true(replica.attempts().last().unwrap().status is Queued)
          assert_eq(replica.attempts().last().unwrap().created_at_ms, queued_at)
          assert_eq(replica.attempts().last().unwrap().started_at_ms, None)
          clock.val = clock.val + 10L
          let started_at = clock.val
          lifecycle_accept(
            backend,
            replica,
            @client.start_attempt_command(
              "start-" + id,
              replica.revision(),
              id~,
            ),
          )
          let attempt = replica.attempts().last().unwrap()
          assert_true(attempt.status is Running)
          assert_eq(attempt.started_at_ms, Some(started_at))
          assert_eq(attempt.finished_at_ms, None)
          assert_eq(attempt.review is Some(Pending), kind is @client.Review)
          clock.val = clock.val + 10L
          lifecycle_accept(
            backend,
            replica,
            @client.finish_attempt_command(
              "finish-" + id,
              replica.revision(),
              id~,
              outcome~,
            ),
          )
          let attempt = replica.attempts().last().unwrap()
          assert_eq(attempt.created_at_ms, queued_at)
          assert_eq(attempt.started_at_ms, Some(started_at))
          assert_eq(attempt.finished_at_ms, Some(clock.val))
          assert_eq(attempt.updated_at_ms, clock.val)
          assert_true(
            match (outcome, attempt.status) {
              (Succeeded, Succeeded)
              | (Failed, Failed)
              | (Cancelled, Cancelled)
              | (Interrupted, Interrupted) => true
              _ => false
            },
          )
          assert_true(replica.tasks()[0].stage is Created)
          // Terminal attempts cannot be started/finished again. Rejections
          // neither increment revision nor publish another event.
          let revision = replica.revision()
          let seq = backend.current_seq()
          for
            command in [
              @client.start_attempt_command("again", revision, id~),
              @client.finish_attempt_command("again", revision, id~, outcome~),
            ] {
            let rejected = backend.handle_command(command)
            assert_false(rejected.accepted)
            assert_eq(rejected.error, Some("invalid_attempt_transition"))
            assert_eq(rejected.current_revision, Some(revision))
            assert_eq(backend.current_seq(), seq)
          }
        }
      }
      assert_eq(replica.attempts().length(), 12)
      assert_eq(replica.revision(), 37L)
      backend.shutdown()
    })
  })
}

///|
async test "manual running attempt recovery is durable Interrupted and cannot be replayed as running" {
  @async.with_timeout(5000, () => {
    let store = @store.MemoryBoardStore()
    let replica = @client.BoardReplica::empty()
    let first = @backend.BoardBackend(store~, now_ms=() => 100L)
    @async.with_task_group(group => {
      first.attach(group)
      assert_true(
        replica.apply_snapshot(first.bootstrap_snapshot().unwrap()) is Applied,
      )
      lifecycle_accept(
        first,
        replica,
        @client.create_task_command(
          "create",
          0L,
          id="t",
          title="Recovery",
          description="",
          priority=@client.Normal,
          definition_of_done=[],
          dependencies=[],
        ),
      )
      lifecycle_accept(
        first,
        replica,
        @client.queue_attempt_command(
          "queue",
          1L,
          id="a",
          task_id="t",
          kind=@client.Execute,
        ),
      )
      lifecycle_accept(
        first,
        replica,
        @client.start_attempt_command("start", 2L, id="a"),
      )
      first.shutdown()
    })
    let recovered = @backend.BoardBackend(store~, now_ms=() => 200L)
    @async.with_task_group(group => {
      recovered.attach(group)
      let snapshot = recovered.bootstrap_snapshot().unwrap()
      assert_eq(snapshot.board_revision, 4L)
      assert_eq(snapshot.last_seq, 1L)
      assert_true(replica.apply_snapshot(snapshot) is Applied)
      let attempt = replica.attempts()[0]
      assert_true(attempt.status is Interrupted)
      assert_eq(attempt.started_at_ms, Some(100L))
      assert_eq(attempt.finished_at_ms, Some(200L))
      assert_true(replica.tasks()[0].stage is Created)
      let persisted = store.load().unwrap()
      assert_eq(persisted.snapshot.revision, 4L)
      let history = recovered.event_history()
      assert_eq(history.length(), 1)
      assert_eq(history[0].kind, "board.attempt.finished")
      for
        command in [
          @client.start_attempt_command("start-new", 4L, id="a"),
          @client.finish_attempt_command(
            "finish-new",
            4L,
            id="a",
            outcome=@client.Succeeded,
          ),
        ] {
        let result = recovered.handle_command(command)
        assert_false(result.accepted)
        assert_eq(result.error, Some("invalid_attempt_transition"))
        assert_eq(result.current_revision, Some(4L))
      }
      assert_eq(recovered.current_seq(), 1L)
      recovered.shutdown()
    })
    let unchanged = @backend.BoardBackend(store~, now_ms=() => 300L)
    @async.with_task_group(group => {
      unchanged.attach(group)
      let snapshot = unchanged.bootstrap_snapshot().unwrap()
      assert_eq(snapshot.board_revision, 4L)
      assert_eq(snapshot.last_seq, 0L)
      assert_eq(unchanged.event_history().length(), 0)
      assert_true(replica.apply_snapshot(snapshot) is Applied)
      assert_eq(replica.attempts()[0].finished_at_ms, Some(200L))
      unchanged.shutdown()
    })
  })
}
