///|
async fn review_service_seed(
  backend : @backend.BoardBackend,
  replica : @client.BoardReplica,
  kind : @client.ClientAttemptKind,
) -> Unit {
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
      title="Manual review",
      description="",
      priority=@client.Normal,
      definition_of_done=[],
      dependencies=[],
    ),
  )
  lifecycle_accept(
    backend,
    replica,
    @client.queue_attempt_command("queue", 1L, id="a", task_id="t", kind~),
  )
}

///|
async test "review decisions persist full authoritative entities independently from finish and task stage" {
  let decisions : Array[
    (@client.ClientRecordableReviewDecision, @client.ClientReviewDecision),
  ] = [
    (@client.Approved, @client.Approved),
    (@client.ChangesRequested, @client.ChangesRequested),
  ]
  for (decision, projected) in decisions {
    let clock = Ref(100L)
    let store = @store.MemoryBoardStore()
    let backend = @backend.BoardBackend(store~, now_ms=() => clock.val)
    @async.with_task_group(group => {
      backend.attach(group)
      let replica = @client.BoardReplica::empty()
      review_service_seed(backend, replica, @client.Review)
      lifecycle_accept(
        backend,
        replica,
        @client.start_attempt_command("start", 2L, id="a"),
      )
      clock.val = 1234L
      let subscription = backend.subscribe(3L, true)
      let result = backend.handle_command(
        @client.record_review_command("record", 3L, id="a", decision~),
      )
      assert_true(result.accepted)
      assert_eq(result.current_revision, Some(4L))
      // Commit hook has already queued the complete entity before submit answers.
      let event = match subscription.next() {
        Event(event) => event
        _ => fail("expected authoritative review event before settlement")
      }
      assert_eq(event.kind, "board.review.recorded")
      assert_eq(event.seq, 4L)
      assert_eq(event.board_revision, 4L)
      assert_eq(event.payload, {
        "attempt_id": "a",
        "task_id": "t",
        "decision": decision.to_wire().to_json(),
        "at_ms": 1234,
        "attempt": {
          "id": "a",
          "task_id": "t",
          "kind": "review",
          "status": "running",
          "review": decision.to_wire().to_json(),
          "created_at_ms": 100,
          "started_at_ms": 100,
          "finished_at_ms": Json::null(),
          "updated_at_ms": 1234,
        },
      })
      assert_true(replica.apply_frame(Event(event)) is Applied)
      let attempt = replica.attempts()[0]
      assert_true(attempt.status is Running)
      assert_true(attempt.review == Some(projected))
      assert_eq(attempt.finished_at_ms, None)
      assert_eq(attempt.updated_at_ms, 1234L)
      assert_true(replica.tasks()[0].stage is Created)
      let before_result = replica.copy()
      assert_true(
        replica.apply_frame(CommandResult(result)) is CommandSettled(_),
      )
      assert_true(replica == before_result)
      let saved = store.load().unwrap()
      assert_eq(saved.snapshot.revision, 4L)
      assert_eq(saved.snapshot.attempts[0].updated_at_ms, 1234L)
      let second = backend.handle_command(
        @client.record_review_command(
          "second",
          4L,
          id="a",
          decision=@client.ChangesRequested,
        ),
      )
      assert_false(second.accepted)
      assert_eq(second.error, Some("invalid_review_transition"))
      assert_eq(second.current_revision, Some(4L))
      assert_eq(backend.current_seq(), 4L)
      clock.val = 2000L
      lifecycle_accept(
        backend,
        replica,
        @client.finish_attempt_command(
          "finish",
          4L,
          id="a",
          outcome=@client.Succeeded,
        ),
      )
      assert_true(replica.attempts()[0].status is Succeeded)
      assert_true(replica.attempts()[0].review == Some(projected))
      assert_eq(replica.attempts()[0].finished_at_ms, Some(2000L))
      assert_true(replica.tasks()[0].stage is Created)
      backend.unsubscribe(subscription)
      backend.shutdown()
    })
  }
}

///|
async test "review rejects wrong kind queued terminal missing and explicit pending without stream changes" {
  for kind in [@client.Discuss, @client.Execute, @client.Review] {
    let backend = @backend.BoardBackend(now_ms=() => 100L)
    @async.with_task_group(group => {
      backend.attach(group)
      let replica = @client.BoardReplica::empty()
      review_service_seed(backend, replica, kind)
      let queued = backend.handle_command(
        @client.record_review_command(
          "queued",
          2L,
          id="a",
          decision=@client.Approved,
        ),
      )
      assert_false(queued.accepted)
      assert_eq(
        queued.error,
        Some(
          if kind is @client.Review {
            "invalid_review_transition"
          } else {
            "invalid_input"
          },
        ),
      )
      assert_eq(queued.current_revision, Some(2L))
      assert_eq(backend.current_seq(), 2L)
      lifecycle_accept(
        backend,
        replica,
        @client.start_attempt_command("start", 2L, id="a"),
      )
      let missing = backend.handle_command(
        @client.record_review_command(
          "missing",
          3L,
          id="missing",
          decision=@client.Approved,
        ),
      )
      assert_eq(missing.error, Some("attempt_not_found"))
      let pending = backend.handle_command({
        command_id: "pending",
        name: "board.review.record",
        expected_revision: 3L,
        args: { "id": "a", "decision": "pending" },
      })
      assert_eq(pending.error, Some("invalid_arguments"))
      assert_eq(backend.current_seq(), 3L)
      if !(kind is @client.Review) {
        let wrong = backend.handle_command(
          @client.record_review_command(
            "wrong",
            3L,
            id="a",
            decision=@client.Approved,
          ),
        )
        assert_eq(wrong.error, Some("invalid_input"))
        assert_eq(backend.current_seq(), 3L)
      }
      lifecycle_accept(
        backend,
        replica,
        @client.finish_attempt_command(
          "finish",
          3L,
          id="a",
          outcome=@client.Cancelled,
        ),
      )
      let terminal = backend.handle_command(
        @client.record_review_command(
          "terminal",
          4L,
          id="a",
          decision=@client.Approved,
        ),
      )
      assert_eq(
        terminal.error,
        Some(
          if kind is @client.Review {
            "invalid_review_transition"
          } else {
            "invalid_input"
          },
        ),
      )
      assert_eq(terminal.current_revision, Some(4L))
      assert_eq(backend.current_seq(), 4L)
      assert_eq(
        replica.attempts()[0].review is Some(Pending),
        kind is @client.Review,
      )
      backend.shutdown()
    })
  }
}

///|
async test "review previsibility persist failure emits nothing and uncertainty preserves a reconciled committed review" {
  let store : HeadlessScriptStore = {
    fail_persists: 0,
    uncertain_persists: 0,
    landed: None,
  }
  let backend = @backend.BoardBackend(store~, now_ms=() => 1234L)
  @async.with_task_group(group => {
    backend.attach(group)
    let replica = @client.BoardReplica::empty()
    review_service_seed(backend, replica, @client.Review)
    lifecycle_accept(
      backend,
      replica,
      @client.start_attempt_command("start", 2L, id="a"),
    )
    let before = backend.event_history()
    store.fail_persists = 1
    let failed = backend.handle_command(
      @client.record_review_command(
        "failed",
        3L,
        id="a",
        decision=@client.Approved,
      ),
    )
    assert_false(failed.accepted)
    assert_eq(failed.error, Some("persistence_failed"))
    assert_eq(failed.current_revision, Some(3L))
    assert_eq(backend.event_history(), before)
    assert_eq(backend.current_seq(), 3L)
    assert_true(
      replica.apply_snapshot(backend.bootstrap_snapshot().unwrap()) is Applied,
    )
    assert_true(replica.attempts()[0].review is Some(Pending))
    store.uncertain_persists = 1
    let uncertain = backend.handle_command(
      @client.record_review_command(
        "uncertain",
        3L,
        id="a",
        decision=@client.ChangesRequested,
      ),
    )
    assert_false(uncertain.accepted)
    assert_eq(uncertain.error, Some("durability_uncertain"))
    assert_eq(uncertain.current_revision, Some(4L))
    let event = backend.event_history().last().unwrap()
    assert_eq(event.kind, "board.review.recorded")
    assert_true(replica.apply_frame(Event(event)) is Applied)
    assert_true(replica.attempts()[0].review is Some(ChangesRequested))
    assert_true(replica.attempts()[0].status is Running)
    assert_eq(replica.attempts()[0].finished_at_ms, None)
    assert_eq(backend.current_seq(), 4L)
    assert_true(
      replica.apply_frame(CommandResult(uncertain)) is CommandSettled(_),
    )
    assert_true(replica.attempts()[0].review is Some(ChangesRequested))
    backend.shutdown()
  })
}

///|
async test "recovered Interrupted review remains pending but cannot accept a new decision" {
  let store = @store.MemoryBoardStore()
  let first = @backend.BoardBackend(store~, now_ms=() => 100L)
  @async.with_task_group(group => {
    first.attach(group)
    let replica = @client.BoardReplica::empty()
    review_service_seed(first, replica, @client.Review)
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
    let replica = @client.BoardReplica::empty()
    assert_true(
      replica.apply_snapshot(recovered.bootstrap_snapshot().unwrap()) is Applied,
    )
    assert_true(replica.attempts()[0].status is Interrupted)
    assert_true(replica.attempts()[0].review is Some(Pending))
    let seq = recovered.current_seq()
    let result = recovered.handle_command(
      @client.record_review_command(
        "record",
        replica.revision(),
        id="a",
        decision=@client.Approved,
      ),
    )
    assert_eq(result.error, Some("invalid_review_transition"))
    assert_false(result.accepted)
    assert_eq(recovered.current_seq(), seq)
    recovered.shutdown()
  })
}
