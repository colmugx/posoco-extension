///|
fn submitted_dependencies() -> Model {
  let (changed, _) = update(
    draft_model(),
    DependencyToggled("b", true),
    test_emit,
    test_env(),
  )
  let (submitted, _) = update(
    changed,
    DependenciesSubmitted,
    test_emit,
    test_env(),
  )
  submitted
}

///|
test "dependency event precedes correlated settlement without optimistic projection" {
  let submitted = submitted_dependencies()
  assert_eq(inspector_task(submitted).unwrap().dependencies, ["a"])
  assert_true(
    submitted.pending is Some({ kind: PendingDependencies(task_id="t"), .. }),
  )
  let (foreign, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(command_result_text("foreign", true, None, Some(1L))),
    ),
    test_emit,
    test_env(),
  )
  assert_true(foreign == submitted)
  let (evented, _) = update(
    submitted,
    SocketEvent(0, Message(dependency_event(["a", "b"]))),
    test_emit,
    test_env(),
  )
  assert_eq(inspector_task(evented).unwrap().dependencies, ["a", "b"])
  assert_eq(evented.replica.revision(), 2L)
  assert_true(evented.pending == submitted.pending)
  assert_false(dependency_conflict(evented, evented.dependency_editor.unwrap()))
  let (settled, command) = update(
    evented,
    SocketEvent(
      0,
      Message(command_result_text("cmd-uuid-1", true, None, Some(2L))),
    ),
    test_emit,
    test_env(),
  )
  assert_true(settled.pending is None)
  assert_true(settled.dependency_editor is None)
  assert_eq(settled.selected_task, Some("t"))
  assert_true(settled.replica == evented.replica)
  assert_true(settled.notice is Some({ severity: Success, .. }))
  debug_inspect(command, content="[]")
}

///|
test "dependency rejections safely preserve independent drafts and authoritative baseline" {
  for
    code in [
      "dependency_not_found", "self_dependency", "duplicate_dependency", "dependency_cycle",
      "persistence_failed",
    ] {
    let submitted = submitted_dependencies()
    let (rejected, command) = update(
      submitted,
      SocketEvent(
        0,
        Message(command_result_text("cmd-uuid-1", false, Some(code), Some(1L))),
      ),
      test_emit,
      test_env(),
    )
    assert_true(rejected.pending is None)
    assert_true(rejected.replica == submitted.replica)
    assert_true(rejected.dependency_editor == submitted.dependency_editor)
    assert_true(rejected.notice is Some({ severity: Error, .. }))
    assert_eq(rejected.notice.unwrap().text, rejection_text(Some(code)))
    assert_false(rejected.retry_pending)
    debug_inspect(command, content="[]")
  }
  assert_eq(rejection_text(Some("/private/store/secret")), rejection_text(None))
}

///|
test "dependency conflict reconciles with Hello only and requires explicit latest draft reload" {
  let submitted = submitted_dependencies()
  let (conflicted, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-1",
          false,
          Some("revision_conflict"),
          Some(2L),
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  assert_true(conflicted.pending is None)
  assert_false(conflicted.replica.has_snapshot())
  assert_true(conflicted.dependency_editor == submitted.dependency_editor)
  assert_true(conflicted.retry_pending)
  let (retrying, _) = update(conflicted, Retry(0), test_emit, test_env())
  let (opened, command) = update(
    retrying,
    SocketEvent(1, Opened),
    test_emit,
    test_env(),
  )
  let expected = @websocket.send(
    "board",
    Text(hello_payload(@client.BoardReplica::empty())),
    failed=_ => test_emit(TransportFailed(1)),
  )
  assert_eq(Repr(command).to_string(), Repr(expected).to_string())
  let (fresh, _) = update(
    opened,
    SocketEvent(
      1,
      Message(
        inspector_snapshot(
          [
            dependency_task_json("t", ["b"]),
            dependency_task_json("a", []),
            dependency_task_json("b", []),
          ],
          revision=2L,
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  assert_eq(fresh.selected_task, Some("t"))
  assert_true(dependency_conflict(fresh, fresh.dependency_editor.unwrap()))
  assert_eq(fresh.dependency_editor.unwrap().dependencies, ["a", "b"])
  let (refreshed, _) = update(
    fresh,
    DependenciesRefreshed,
    test_emit,
    test_env(),
  )
  assert_eq(refreshed.dependency_editor.unwrap().dependencies, ["b"])
  assert_false(
    dependency_conflict(refreshed, refreshed.dependency_editor.unwrap()),
  )
}

///|
test "dependency durability uncertainty never rolls back an event applied projection" {
  let submitted = submitted_dependencies()
  let (evented, _) = update(
    submitted,
    SocketEvent(0, Message(dependency_event(["a", "b"]))),
    test_emit,
    test_env(),
  )
  let (uncertain, command) = update(
    evented,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-1",
          false,
          Some("durability_uncertain"),
          Some(2L),
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  assert_true(uncertain.replica == evented.replica)
  assert_eq(inspector_task(uncertain).unwrap().dependencies, ["a", "b"])
  assert_true(uncertain.pending is None)
  assert_true(uncertain.dependency_editor == submitted.dependency_editor)
  assert_true(uncertain.notice is Some({ severity: Warning, .. }))
  assert_true(
    dependency_conflict(uncertain, uncertain.dependency_editor.unwrap()),
  )
  debug_inspect(command, content="[]")
  let (mismatch, _) = update(
    evented,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-1",
          false,
          Some("durability_uncertain"),
          Some(3L),
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  assert_false(mismatch.replica.has_snapshot())
  assert_true(mismatch.retry_pending)
  assert_true(mismatch.dependency_editor == submitted.dependency_editor)
}

///|
test "accepted dependency result with mismatching revision still refreshes without projecting" {
  let submitted = submitted_dependencies()
  let (settled, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(command_result_text("cmd-uuid-1", true, None, Some(2L))),
    ),
    test_emit,
    test_env(),
  )
  assert_false(settled.replica.has_snapshot())
  assert_true(settled.pending is None)
  assert_true(settled.dependency_editor is None)
  assert_true(settled.retry_pending)
}
