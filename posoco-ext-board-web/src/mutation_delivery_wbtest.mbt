///|
test "ordinary rejections still reconcile any reported stale revision" {
  for
    code in [
      "invalid_input", "persistence_failed", "board_timeout", "board_initializing",
      "board_unavailable",
    ] {
    let env = test_env()
    let (opened, _) = update(
      seeded_online("t", "ready"),
      EditOpened("t"),
      test_emit,
      env,
    )
    let (pending, _) = update(opened, SubmitRequested, test_emit, env)
    let (settled, _) = update(
      pending,
      SocketEvent(
        0,
        Message(command_result_text("cmd-uuid-1", false, Some(code), Some(2L))),
      ),
      test_emit,
      env,
    )
    assert_true(settled.pending is None)
    assert_false(settled.replica.has_snapshot())
    assert_true(settled.retry_pending)
    assert_true(settled.editor == pending.editor)
    let (retrying, _) = update(settled, Retry(0), test_emit, env)
    let (_, sent) = update(retrying, SocketEvent(1, Opened), test_emit, env)
    assert_eq(
      Repr(sent).to_string(),
      Repr(
        @websocket.send(
          "board",
          Text(hello_payload(@client.BoardReplica::empty())),
        ),
      ).to_string(),
    )
  }
}

///|
test "a late Hello send failure also reconciles a pending mutation" {
  let env = test_env()
  let (pending, _) = update(
    seeded_online("t", "ready"),
    MoveRequested("t", Running),
    test_emit,
    env,
  )
  let (lost, _) = update(pending, TransportFailed(0), test_emit, env)
  assert_true(lost.pending is None)
  assert_false(lost.replica.has_snapshot())
  assert_true(lost.retry_pending)
  let (retrying, command) = update(lost, Retry(0), test_emit, env)
  assert_false(Repr(command).to_string().contains("WebSocketSend"))
  let (_, hello) = update(retrying, SocketEvent(1, Opened), test_emit, env)
  debug_inspect(
    hello,
    content=(
      #|WebSocketSend(
      #|  "board",
      #|  Text("{\"type\":\"hello\",\"last_seq\":0,\"protocol_version\":1,\"has_board_snapshot\":false}"),
      #|)
    ),
  )
}

///|
test "returned mutation commands encode the current wire contract" {
  let env = test_env()
  let model = seeded_online("t", "ready")
  let (opened, _) = update(model, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship"), test_emit, env)
  let (_, sent) = update(drafted, SubmitRequested, test_emit, env)
  debug_inspect(
    sent,
    content=(
      #|WebSocketSend(
      #|  "board",
      #|  Text("{\"type\":\"command\",\"command_id\":\"cmd-uuid-1\",\"name\":\"board.task.create\",\"expected_revision\":1,\"args\":{\"id\":\"task-uuid-1\",\"title\":\"Ship\",\"description\":\"\",\"priority\":\"normal\",\"definition_of_done\":[],\"dependencies\":[]}}"),
      #|)
    ),
  )
  let (edit, _) = update(model, EditOpened("t"), test_emit, env)
  let (evented, _) = update(
    edit,
    SocketEvent(0, Message(task_event_text("t", "running", 1, 2))),
    test_emit,
    env,
  )
  let (submitted, edit_sent) = update(evented, SubmitRequested, test_emit, env)
  assert_true(submitted.pending is Some({ revision: 2L, .. }))
  let expected = update_command("uuid-1", 2L, "t", evented.editor.unwrap())
  assert_eq(
    Repr(edit_sent).to_string(),
    Repr(send_command(0, expected, test_emit)).to_string(),
  )
  let (_, move_sent) = update(
    model,
    MoveRequested("t", Running),
    test_emit,
    env,
  )
  assert_eq(
    Repr(move_sent).to_string(),
    Repr(send_command(0, move_command("uuid-1", 1L, "t", Running), test_emit)).to_string(),
  )
}

///|
test "stale edit target is rejected before generating an id or sending" {
  let calls = Ref(0)
  let env : Env = {
    url: "unused",
    uuid: () => {
      calls.val = calls.val + 1
      Some("uuid-1")
    },
  }
  let (opened, _) = update(
    seeded_online("t", "ready"),
    EditOpened("t"),
    test_emit,
    env,
  )
  let replica = @client.BoardReplica::empty()
  ignore(replica.apply_text(snapshot_text([], 2)))
  let stale = { ..opened, replica, }
  let (blocked, command) = update(stale, SubmitRequested, test_emit, env)
  assert_true(blocked.pending is None)
  assert_true(blocked.editor is None)
  assert_true(blocked.notice is Some(_))
  assert_eq(calls.val, 0)
  debug_inspect(command, content="[]")
}

///|
test "queued editor events cannot replace a pending draft" {
  let env = test_env()
  let (opened, _) = update(
    seeded_online("t", "ready"),
    EditOpened("t"),
    test_emit,
    env,
  )
  let (pending, _) = update(opened, SubmitRequested, test_emit, env)
  for
    message in [
      EditorCancelled,
      TitleChanged("other"),
      DescriptionChanged("other"),
      PriorityChanged("critical"),
      DefinitionOfDoneChanged("other"),
      CreateOpened,
      EditOpened("t"),
    ] {
    let (unchanged, command) = update(pending, message, test_emit, env)
    assert_true(unchanged == pending)
    debug_inspect(command, content="[]")
  }
}

///|
test "terminal error discards unconfirmed baseline without retry" {
  let env = test_env()
  let (pending, _) = update(
    seeded_online("t", "ready"),
    MoveRequested("t", Running),
    test_emit,
    env,
  )
  let text = @protocol.encode_server_frame(
    Error(code="unsupported_protocol_version", message="unsupported"),
  )
  let (terminal, command) = update(
    pending,
    SocketEvent(0, Message(text)),
    test_emit,
    env,
  )
  assert_true(terminal.pending is None)
  assert_false(terminal.replica.has_snapshot())
  assert_false(terminal.retry_pending)
  assert_true(terminal.connection is ProtocolError(_))
  debug_inspect(command, content="WebSocketClose(\"board\", None, None)")
}

///|
test "uncertain persistence never rolls back an already applied authoritative event" {
  let env = test_env()
  let (pending, _) = update(
    seeded_online("t", "ready"),
    MoveRequested("t", Running),
    test_emit,
    env,
  )
  let (evented, _) = update(
    pending,
    SocketEvent(0, Message(task_event_text("t", "running", 1, 2))),
    test_emit,
    env,
  )
  assert_true(evented.pending is Some(_))
  let (settled, command) = update(
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
    env,
  )
  assert_true(settled.pending is None)
  assert_true(settled.replica == evented.replica)
  assert_true(settled.replica.tasks()[0].stage is Running)
  assert_false(settled.retry_pending)
  assert_true(settled.notice is Some({ severity: Warning, .. }))
  debug_inspect(command, content="[]")
}
