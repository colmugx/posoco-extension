///|
test "authoritative dependency changes block overwrite until explicit reload" {
  let original = draft_model()
  let (edited, _) = update(
    original,
    DependencyToggled("b", true),
    test_emit,
    test_env(),
  )
  let (changed, _) = update(
    edited,
    SocketEvent(0, Message(dependency_event(["b"]))),
    test_emit,
    test_env(),
  )
  let draft = changed.dependency_editor.unwrap()
  assert_eq(draft.base_dependencies, ["a"])
  assert_eq(draft.dependencies, ["a", "b"])
  assert_eq(inspector_task(changed).unwrap().dependencies, ["b"])
  assert_true(dependency_conflict(changed, draft))
  assert_false(dependency_save_allowed(changed, draft))
  let calls = Ref(0)
  let env : Env = {
    url: "unused",
    uuid: () => {
      calls.val = calls.val + 1
      Some("uuid-1")
    },
  }
  let (blocked, command) = update(
    changed,
    DependenciesSubmitted,
    test_emit,
    env,
  )
  assert_true(blocked.pending is None)
  assert_eq(calls.val, 0)
  assert_true(blocked.dependency_editor == changed.dependency_editor)
  assert_true(blocked.notice is Some({ severity: Warning, .. }))
  debug_inspect(command, content="[]")
  let (refreshed, _) = update(blocked, DependenciesRefreshed, test_emit, env)
  assert_eq(refreshed.dependency_editor.unwrap().base_dependencies, ["b"])
  assert_eq(refreshed.dependency_editor.unwrap().dependencies, ["b"])
  assert_false(
    dependency_conflict(refreshed, refreshed.dependency_editor.unwrap()),
  )
  let (submitted, _) = update(refreshed, DependenciesSubmitted, test_emit, env)
  assert_true(submitted.pending is Some({ revision: 2L, .. }))
  assert_eq(calls.val, 1)
}

///|
test "a single task has no selectable dependency candidates" {
  let (single, _) = update(
    draft_model(),
    SocketEvent(0, Message(inspector_snapshot([dependency_task_json("t", [])]))),
    test_emit,
    test_env(),
  )
  assert_true(dependency_candidates(single, "t").is_empty())
  assert_eq(single.dependency_editor.unwrap().dependencies, ["a"])
  assert_eq(dependency_title(single, "a"), "Unavailable task")
}

///|
test "missing candidates are retained visibly until explicit removal" {
  let original = draft_model()
  let (missing, _) = update(
    original,
    SocketEvent(
      0,
      Message(
        inspector_snapshot(
          [dependency_task_json("t", ["a"]), dependency_task_json("b", [])],
          revision=2L,
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  assert_eq(missing.dependency_editor.unwrap().dependencies, ["a"])
  assert_eq(dependency_title(missing, "a"), "Unavailable task")
  assert_eq(dependency_title(missing, "b"), "Title b")
  assert_eq(dependency_candidates(missing, "t").length(), 1)
  let (removed, _) = update(
    missing,
    DependencyToggled("a", false),
    test_emit,
    test_env(),
  )
  assert_eq(removed.dependency_editor.unwrap().dependencies, [])
  assert_eq(inspector_task(removed).unwrap().dependencies, ["a"])
}

///|
test "unrelated revisions use live revision without resetting the dependency draft" {
  let original = draft_model()
  let wire = @protocol.encode_server_frame(
    Event({
      seq: 1L,
      board_revision: 2L,
      kind: "board.task.updated",
      scope: None,
      payload: { "task_id": "b", "task": dependency_task_json("b", []) },
    }),
  )
  let (updated, _) = update(
    original,
    SocketEvent(0, Message(wire)),
    test_emit,
    test_env(),
  )
  assert_true(updated.dependency_editor == original.dependency_editor)
  assert_false(dependency_conflict(updated, updated.dependency_editor.unwrap()))
  let (pending, command) = update(
    updated,
    DependenciesSubmitted,
    test_emit,
    test_env(),
  )
  assert_true(
    pending.pending
    is Some(
      {
        command_id: "cmd-uuid-1",
        kind: PendingDependencies(task_id="t"),
        revision: 2L,
      }
    ),
  )
  let expected = @client.set_task_dependencies_command(
    "cmd-uuid-1",
    2L,
    id="t",
    dependencies=["a"],
  )
  assert_eq(
    Repr(command).to_string(),
    Repr(send_command(0, expected, test_emit)).to_string(),
  )
  assert_true(pending.replica == updated.replica)
}

///|
test "dependency edits require an authoritative online free mutation slot" {
  for
    connection in [Connecting, Reconnecting, Offline, ProtocolError("private")] {
    let model = { ..draft_model(), connection, }
    for
      message in [
        DependencyToggled("b", true),
        DependenciesCleared,
        DependenciesRefreshed,
        DependenciesSubmitted,
      ] {
      let (blocked, command) = update(model, message, test_emit, test_env())
      assert_true(blocked == model)
      debug_inspect(command, content="[]")
    }
  }
  let stale = { ..draft_model(), replica: @client.BoardReplica::empty(), }
  let (blocked, command) = update(
    stale,
    DependenciesSubmitted,
    test_emit,
    test_env(),
  )
  assert_true(blocked == stale)
  debug_inspect(command, content="[]")
  let (pending, _) = update(
    draft_model(),
    DependenciesSubmitted,
    test_emit,
    test_env(),
  )
  for
    message in [
      DependencyToggled("b", true),
      DependenciesCleared,
      DependenciesRefreshed,
      DependenciesCancelled,
      DependenciesSubmitted,
      CreateOpened,
      EditOpened("t"),
      MoveRequested("t", Running),
    ] {
    let (blocked, command) = update(pending, message, test_emit, test_env())
    assert_true(blocked == pending)
    debug_inspect(command, content="[]")
  }
  let (other, _) = update(pending, TaskSelected("b"), test_emit, test_env())
  assert_eq(other.selected_task, Some("b"))
  assert_true(other.pending == pending.pending)
}

///|
test "clear all is a detached draft change followed by exact typed explicit save" {
  let original = draft_model()
  let (cleared, _) = update(
    original,
    DependenciesCleared,
    test_emit,
    test_env(),
  )
  assert_true(cleared.pending is None)
  assert_eq(inspector_task(cleared).unwrap().dependencies, ["a"])
  let (pending, command) = update(
    cleared,
    DependenciesSubmitted,
    test_emit,
    test_env(),
  )
  let expected = @client.set_task_dependencies_command(
    "cmd-uuid-1",
    1L,
    id="t",
    dependencies=[],
  )
  assert_eq(expected.args, { "id": "t", "dependencies": [] })
  assert_eq(
    Repr(command).to_string(),
    Repr(send_command(0, expected, test_emit)).to_string(),
  )
  assert_eq(inspector_task(pending).unwrap().dependencies, ["a"])
}

///|
test "missing secure UUID never submits a dependency mutation" {
  let original = draft_model()
  let (blocked, command) = update(
    original,
    DependenciesSubmitted,
    test_emit,
    missing_uuid_env(),
  )
  assert_true(blocked.pending is None)
  assert_true(blocked.replica == original.replica)
  assert_true(blocked.dependency_editor == original.dependency_editor)
  assert_true(blocked.notice is Some({ severity: Error, .. }))
  debug_inspect(command, content="[]")
}
