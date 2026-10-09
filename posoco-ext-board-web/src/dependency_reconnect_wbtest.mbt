///|
test "dependency send failure discards uncertainty without resubmitting or losing draft" {
  let submitted = submitted_dependencies()
  for
    message in [
      SendFailed(0, "cmd-uuid-1"),
      TransportFailed(0),
      SocketEvent(0, Errored),
    ] {
    let (lost, _) = update(submitted, message, test_emit, test_env())
    assert_true(lost.pending is None)
    assert_false(lost.replica.has_snapshot())
    assert_true(lost.retry_pending)
    assert_true(lost.dependency_editor == submitted.dependency_editor)
    assert_eq(lost.selected_task, Some("t"))
    assert_true(inspector_task(lost) is None)
    let (retrying, _) = update(lost, Retry(0), test_emit, test_env())
    let (opened, command) = update(
      retrying,
      SocketEvent(1, Opened),
      test_emit,
      test_env(),
    )
    assert_true(opened.pending is None)
    let hello = hello_payload(opened.replica)
    assert_true(
      @protocol.decode_client_frame(hello)
      is Ok(Hello({ last_seq: 0L, has_board_snapshot: false, .. })),
    )
    let expected = @websocket.send("board", Text(hello), failed=_ => {
      test_emit(TransportFailed(1))
    })
    assert_eq(Repr(command).to_string(), Repr(expected).to_string())
  }
}

///|
test "dependency stale generation and foreign send callbacks cannot clear current pending" {
  let submitted = { ..submitted_dependencies(), generation: 3, }
  for
    message in [
      SendFailed(2, "cmd-uuid-1"),
      SendFailed(3, "foreign"),
      TransportFailed(2),
      SocketEvent(2, Errored),
      SocketEvent(
        2,
        Message(command_result_text("cmd-uuid-1", true, None, Some(1L))),
      ),
    ] {
    let (unchanged, command) = update(submitted, message, test_emit, test_env())
    assert_true(unchanged == submitted)
    debug_inspect(command, content="[]")
  }
}

///|
test "ordinary dependency editor reconnect retains baseline and draft with baseline aware Hello" {
  let original = draft_model()
  let (lost, _) = update(
    original,
    SocketEvent(0, Errored),
    test_emit,
    test_env(),
  )
  assert_true(lost.replica == original.replica)
  assert_true(lost.dependency_editor == original.dependency_editor)
  let (retrying, _) = update(lost, Retry(0), test_emit, test_env())
  let (opened, command) = update(
    retrying,
    SocketEvent(1, Opened),
    test_emit,
    test_env(),
  )
  assert_true(opened.connection is Online)
  let hello = hello_payload(original.replica)
  assert_true(
    @protocol.decode_client_frame(hello)
    is Ok(Hello({ has_board_snapshot: true, .. })),
  )
  let expected = @websocket.send("board", Text(hello), failed=_ => {
    test_emit(TransportFailed(1))
  })
  assert_eq(Repr(command).to_string(), Repr(expected).to_string())
}

///|
test "authoritative replacement removes a pending target without stale inspector render" {
  let submitted = submitted_dependencies()
  let (missing, _) = update(
    submitted,
    SocketEvent(0, Message(inspector_snapshot([dependency_task_json("b", [])]))),
    test_emit,
    test_env(),
  )
  assert_true(missing.selected_task is None)
  assert_true(missing.dependency_editor is None)
  assert_true(missing.pending == submitted.pending)
  assert_true(inspector_task(missing) is None)
  let (settled, _) = update(
    missing,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-1",
          false,
          Some("task_not_found"),
          Some(1L),
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  assert_true(settled.pending is None)
  assert_true(settled.selected_task is None)
  assert_eq(settled.replica.tasks().length(), 1)
}
