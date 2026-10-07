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
async test "runtime command rejection reports unavailable revision when detached or closed" {
  let server : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(server~, opener~, now_ms=() => 1234L)
  let command : @protocol.BoardClientCommand = {
    command_id: "correlation",
    name: "board.attempt.start",
    expected_revision: 0,
    args: { "id": "attempt" },
  }
  let detached = runtime.handle_command(command)
  assert_eq(detached.error, Some("board_initializing"))
  assert_eq(detached.current_revision, None)
  assert_false(detached.accepted)
  runtime.shutdown()
  let closed = runtime.handle_command(command)
  assert_eq(closed.error, Some("board_unavailable"))
  assert_eq(closed.current_revision, None)
  assert_eq(runtime.hub.current_seq(), 0L)
}

///|
async test "wire rejection reports committed revision without minting a stream sequence" {
  let server : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(server~, opener~)
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    let rejected = runtime.handle_command({
      command_id: "",
      name: "board.attempt.start",
      expected_revision: 0,
      args: { "id": "attempt" },
    })
    assert_eq(rejected.error, Some("invalid_command"))
    assert_eq(rejected.current_revision, Some(0L))
    assert_false(rejected.accepted)
    assert_eq(runtime.hub.current_seq(), 0L)
    runtime.shutdown()
  })
}
