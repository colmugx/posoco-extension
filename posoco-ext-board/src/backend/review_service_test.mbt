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
        "decision": Json(decision.to_wire()),
        "at_ms": 1234,
        "attempt": {
          "id": "a",
          "task_id": "t",
          "kind": "review",
          "status": "running",
          "review": Json(decision.to_wire()),
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

///|
async test "request changes commits the decision and returns the ticket to ready in one event" {
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
    let mut revision = 3L
    for
      stage in [
        @client.Refining,
        @client.Ready,
        @client.Running,
        @client.Review,
      ] {
      lifecycle_accept(
        backend,
        replica,
        @client.move_task_command("move", revision, id="t", to=stage),
      )
      revision += 1L
    }
    assert_true(replica.tasks()[0].stage is @client.Review)
    clock.val = 1234L
    // Whitespace-only feedback is not a decision: the domain rejects it and
    // the stream stays untouched.
    let empty = backend.handle_command(
      @client.request_changes_command(
        "empty",
        revision,
        attempt_id="a",
        feedback="   ",
      ),
    )
    assert_false(empty.accepted)
    assert_eq(empty.error, Some("invalid_input"))
    assert_eq(empty.current_revision, Some(revision))
    assert_eq(backend.current_seq(), revision)
    lifecycle_accept(
      backend,
      replica,
      @client.request_changes_command(
        "changes",
        revision,
        attempt_id="a",
        feedback="  Add the missing regression test.\n",
      ),
    )
    let event = backend.event_history().last().unwrap()
    assert_eq(event.kind, "board.task.review_changes_requested")
    assert_eq(event.board_revision, revision + 1L)
    assert_eq(event.payload, {
      "task_id": "t",
      "task": {
        "id": "t",
        "title": "Manual review",
        "description": "",
        "stage": "ready",
        "priority": "normal",
        "definition_of_done": [],
        "dependencies": [],
        "created_at_ms": 100,
        "updated_at_ms": 1234,
        "ready_since_ms": 1234,
        "model": Json::null(),
        "review": Json::null(),
        "review_feedback": "Add the missing regression test.",
      },
      "attempt_id": "a",
      "attempt": {
        "id": "a",
        "task_id": "t",
        "kind": "review",
        "status": "running",
        "review": "changes_requested",
        "created_at_ms": 100,
        "started_at_ms": 100,
        "finished_at_ms": Json::null(),
        "updated_at_ms": 1234,
      },
      "feedback": "Add the missing regression test.",
      "at_ms": 1234,
    })
    // lifecycle_accept applied that single event: both records moved.
    let task = replica.tasks()[0]
    assert_true(task.stage is @client.Ready)
    assert_eq(task.review_feedback, Some("Add the missing regression test."))
    assert_eq(task.ready_since_ms, Some(1234L))
    let attempt = replica.attempts()[0]
    assert_true(attempt.review is Some(@client.ChangesRequested))
    assert_true(attempt.status is @client.Running)
    // One revision settled the whole decision, so there is nothing left to
    // request again on this attempt.
    let second = backend.handle_command(
      @client.request_changes_command(
        "second",
        revision + 1L,
        attempt_id="a",
        feedback="one more test",
      ),
    )
    assert_eq(second.error, Some("invalid_review_transition"))
    assert_eq(backend.current_seq(), revision + 1L)
    // The durable snapshot keeps the feedback with the returned ticket.
    let saved = store.load().unwrap()
    assert_eq(saved.snapshot.revision, revision + 1L)
    assert_eq(saved.snapshot.tasks[0].stage, @domain.Ready)
    assert_eq(saved.snapshot.tasks[0].ready_since_ms, Some(1234L))
    assert_eq(
      saved.snapshot.tasks[0].review_feedback,
      Some("Add the missing regression test."),
    )
    assert_eq(saved.snapshot.attempts[0].review, Some(@domain.ChangesRequested))
    backend.shutdown()
  })
}
