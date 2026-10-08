///|
test "command domain errors are stable wire codes without entity or reason detail" {
  let task = @domain.BoardTaskId("private-task")
  let attempt = @domain.AttemptId("private-attempt")
  let cases : Array[(@domain.BoardError, String)] = [
    (RevisionConflict(expected=0, actual=1), "revision_conflict"),
    (TaskMissing(task~), "task_not_found"),
    (AttemptMissing(attempt~), "attempt_not_found"),
    (InvalidTransition(from=Created, to=Done), "invalid_transition"),
    (
      InvalidAttemptTransition(attempt~, from=Queued, to=Succeeded),
      "invalid_attempt_transition",
    ),
    (
      InvalidReviewTransition(attempt~, current=None, requested=Approved),
      "invalid_review_transition",
    ),
    (DependencyMissing(task~, dependency=task), "dependency_not_found"),
    (SelfDependency(task~), "self_dependency"),
    (DuplicateDependency(task~, dependency=task), "duplicate_dependency"),
    (DependencyCycle(cycle=[task]), "dependency_cycle"),
    (DuplicateTask(task~), "duplicate_task"),
    (DuplicateAttempt(attempt~), "duplicate_attempt"),
    (InvalidInput(reason="secret diagnostic"), "invalid_input"),
  ]
  for (error, code) in cases {
    assert_eq(board_domain_error_code(error), code)
  }
}

///|
test "command coordinator errors redact store details" {
  let cases : Array[(@coordinator.BoardCoordinatorError, String)] = [
    (NotAttached, "board_initializing"),
    (Initializing, "board_initializing"),
    (Closed, "board_unavailable"),
    (TimedOut, "board_timeout"),
    (Rejected(InvalidInput(reason="secret")), "invalid_input"),
    (
      DurabilityUncertain("secret filesystem diagnostic"),
      "durability_uncertain",
    ),
    (RestoreFailed(Domain(InvalidInput(reason="secret"))), "board_unavailable"),
    (PersistFailed(@store.Io("private path/errno")), "persistence_failed"),
    (RestoreFailed(Store(@store.Io("private temp path"))), "board_unavailable"),
  ]
  for (error, code) in cases {
    assert_eq(board_coordinator_error_code(error), code)
  }
}

///|
async test "backend command rejection reports unavailable revision when detached or closed" {
  let backend = BoardBackend::BoardBackend(now_ms=() => 1234L)
  let command : @protocol.BoardClientCommand = {
    command_id: "correlation",
    name: "board.attempt.start",
    expected_revision: 0,
    args: { "id": "attempt" },
  }
  let detached = backend.handle_command(command)
  assert_eq(detached.error, Some("board_initializing"))
  assert_eq(detached.current_revision, None)
  assert_false(detached.accepted)
  backend.shutdown()
  let closed = backend.handle_command(command)
  assert_eq(closed.error, Some("board_unavailable"))
  assert_eq(closed.current_revision, None)
  assert_eq(backend.current_seq(), 0L)
}

///|
async test "wire rejection reports committed revision without minting a stream sequence" {
  let backend = BoardBackend::BoardBackend()
  @async.with_task_group(group => {
    backend.attach(group)
    assert_true(backend.coordinator.wait_ready() is Ok(_))
    let rejected = backend.handle_command({
      command_id: "",
      name: "board.attempt.start",
      expected_revision: 0,
      args: { "id": "attempt" },
    })
    assert_eq(rejected.error, Some("invalid_command"))
    assert_eq(rejected.current_revision, Some(0L))
    assert_false(rejected.accepted)
    assert_eq(backend.current_seq(), 0L)
    backend.shutdown()
  })
}

///|
async test "backend streams committed domain events into the owned hub" {
  let backend = BoardBackend::BoardBackend()
  // Before attach the domain is unreachable.
  assert_true(
    backend.coordinator.submit(command=backend_create("t1", 0L))
    is Err(NotAttached),
  )
  @async.with_task_group(group => {
    backend.attach(group)
    // Loading is asynchronous; readiness gates every domain API use.
    assert_true(backend.coordinator.wait_ready() is Ok(_))
    assert_eq(backend.current_seq(), 0L)
    assert_eq(backend.coordinator.stream_cursor(), 0L)
    let events = backend.coordinator.submit(command=backend_create("t1", 0L))
    assert_eq(events.unwrap().length(), 1)
    // The commit projected into the owned hub with the committed revision.
    assert_eq(backend.current_seq(), 1L)
    assert_eq(backend.coordinator.stream_cursor(), 1L)
    let streamed = backend.event_history()
    assert_eq(streamed.length(), 1)
    assert_eq(streamed[0].seq, 1L)
    assert_eq(streamed[0].board_revision, 1L)
    assert_eq(streamed[0].kind, "board.task.created")
    assert_eq(streamed[0].scope, None)
    assert_eq(backend.coordinator.revision().unwrap(), 1L)
    // Telemetry shares the sequence space but never moves the revision.
    let tick = backend.publish_telemetry(
      board_revision=0L,
      kind="tick",
      payload=Json::null(),
    )
    assert_eq(tick.seq, 2L)
    assert_eq(backend.coordinator.revision().unwrap(), 1L)
    // Repeated attach is idempotent for the coordinator and the hook.
    backend.attach(group)
    let _ = backend.coordinator.submit(command=backend_create("t2", 1L))
    assert_eq(backend.coordinator.revision().unwrap(), 2L)
    assert_eq(backend.current_seq(), 3L)
    assert_eq(backend.coordinator.stream_cursor(), 3L)
    backend.shutdown()
  })
  // Shutdown closes coordinator admission...
  assert_true(backend.coordinator.revision() is Err(Closed))
  assert_true(
    backend.coordinator.submit(command=backend_create("t4", 2L)) is Err(Closed),
  )
  // ...and a fresh attach restores the backend's durable board instead of
  // starting over: two committed tasks, an intact hub sequence and the
  // stream cursor reading the live hub head.
  @async.with_task_group(group => {
    backend.attach(group)
    assert_true(backend.coordinator.wait_ready() is Ok(_))
    assert_eq(backend.coordinator.revision().unwrap(), 2L)
    assert_eq(backend.coordinator.stream_cursor(), 3L)
    assert_eq(backend.coordinator.tasks().unwrap().length(), 2)
    let _ = backend.coordinator.submit(command=backend_create("t4", 2L))
    assert_eq(backend.coordinator.revision().unwrap(), 3L)
    assert_eq(backend.current_seq(), 4L)
    assert_eq(backend.coordinator.stream_cursor(), 4L)
    // The authoritative bootstrap answers the exact hub boundary it read.
    let frame = backend.bootstrap_snapshot().unwrap()
    assert_eq(frame.last_seq, 4L)
    assert_eq(frame.board_revision, 3L)
    backend.shutdown()
  })
}

///|
async test "command chain commits the durable truth across all eight names" {
  let backend = BoardBackend::BoardBackend(now_ms=() => 1234L)
  @async.with_task_group(group => {
    backend.attach(group)
    assert_true(backend.coordinator.wait_ready() is Ok(_))
    let create_args : Json = {
      "id": "t1",
      "title": "task t1",
      "description": "",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    }
    let chain : Array[(String, String, Int64, Json)] = [
      ("chain-1", "board.task.create", 0L, create_args),
      (
        "chain-2",
        "board.task.update",
        1L,
        { "id": "t1", "title": "renamed t1" },
      ),
      (
        "chain-3",
        "board.task.set_dependencies",
        2L,
        { "id": "t1", "dependencies": [] },
      ),
      ("chain-4", "board.task.move", 3L, { "id": "t1", "to": "refining" }),
      (
        "chain-5",
        "board.attempt.queue",
        4L,
        { "id": "a1", "task_id": "t1", "kind": "review" },
      ),
      ("chain-6", "board.attempt.start", 5L, { "id": "a1" }),
      (
        "chain-7",
        "board.review.record",
        6L,
        { "id": "a1", "decision": "approved" },
      ),
      (
        "chain-8",
        "board.attempt.finish",
        7L,
        { "id": "a1", "outcome": "succeeded" },
      ),
    ]
    for i, entry in chain {
      let (command_id, name, rev, args) = entry
      let result = backend.handle_command({
        command_id,
        name,
        expected_revision: rev,
        args,
      })
      assert_eq(result.accepted, true)
      assert_eq(result.current_revision, Some((i + 1).to_int64()))
    }
    assert_eq(backend.current_seq(), 8L)
    assert_eq(backend.coordinator.revision(), Ok(8L))
    let task = backend.coordinator
      .task(id=@domain.BoardTaskId::BoardTaskId("t1"))
      .unwrap()
      .unwrap()
    assert_eq(task.title, "renamed t1")
    assert_eq(task.stage, @domain.Refining)
    assert_eq(task.updated_at_ms, 1234L)
    let attempt = backend.coordinator
      .attempt(id=@domain.AttemptId::AttemptId("a1"))
      .unwrap()
      .unwrap()
    assert_eq(attempt.status, @domain.Succeeded)
    assert_eq(attempt.review, Some(@domain.Approved))
    backend.shutdown()
  })
}
