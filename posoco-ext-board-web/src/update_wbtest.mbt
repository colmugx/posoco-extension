///|
test "opened sends baseline-aware Hello and empty replay settles reconnect" {
  let empty = Model::empty(true)
  let (opened, _) = update(empty, SocketEvent(0, Opened), test_emit, "unused")
  assert_true(opened.connection is Connecting)
  match @protocol.decode_client_frame(hello_payload(opened.replica)) {
    Ok(Hello(hello)) => {
      assert_eq(hello.last_seq, 0L)
      assert_false(hello.has_board_snapshot)
      assert_eq(hello.protocol_version, @protocol.protocol_version())
    }
    _ => fail("expected Hello")
  }
  let snapshot = @protocol.encode_server_frame(
    Snapshot({
      protocol_version: 1,
      last_seq: 0L,
      board_revision: 0L,
      payload: {
        "board": { "revision": 0, "tasks": [], "attempts": [] },
        "events": [],
      },
    }),
  )
  let (online, _) = update(
    opened,
    SocketEvent(0, Message(snapshot)),
    test_emit,
    "unused",
  )
  let (waiting, _) = update(online, TransportFailed(0), test_emit, "unused")
  let (retrying, _) = update(waiting, Retry(0), test_emit, "unused")
  let (resumed, _) = update(
    retrying,
    SocketEvent(1, Opened),
    test_emit,
    "unused",
  )
  assert_true(resumed.connection is Online)
  assert_true(resumed.replica.has_snapshot())
  assert_eq(resumed.retry_attempt, 1)
  match @protocol.decode_client_frame(hello_payload(resumed.replica)) {
    Ok(Hello(hello)) => {
      assert_eq(hello.last_seq, online.replica.last_seq())
      assert_true(hello.has_board_snapshot)
    }
    _ => fail("expected baseline-aware Hello")
  }
}

///|
fn test_emit(_msg : Msg) -> @rabbita.Cmd {
  @rabbita.none
}

///|
test "reconnect is bounded single pending and old callbacks are ignored" {
  let original = Model::empty(true)
  let (waiting, _) = update(
    original,
    TransportFailed(0),
    test_emit,
    "ws://board/ws?token=private",
  )
  assert_true(waiting.connection is Reconnecting)
  assert_true(waiting.retry_pending)
  assert_eq(waiting.retry_attempt, 1)
  let (duplicate, _) = update(
    waiting,
    SocketEvent(0, Errored),
    test_emit,
    "unused",
  )
  assert_eq(duplicate.retry_attempt, 1)
  let (next, _) = update(waiting, Retry(0), test_emit, "unused")
  assert_eq(next.generation, 1)
  assert_false(next.retry_pending)
  let (stale, _) = update(next, TransportFailed(0), test_emit, "unused")
  assert_eq(stale.generation, 1)
  assert_false(stale.retry_pending)
  let (late_retry, _) = update(next, Retry(0), test_emit, "unused")
  assert_eq(late_retry.generation, 1)
}

///|
test "snapshot resets backoff and replica updates do not mutate previous model" {
  let original = { ..Model::empty(true), retry_attempt: 5, }
  let text = @protocol.encode_server_frame(
    Snapshot({
      protocol_version: 1,
      last_seq: 0L,
      board_revision: 0L,
      payload: {
        "board": { "revision": 0, "tasks": [], "attempts": [] },
        "events": [],
      },
    }),
  )
  let (online, _) = update(
    original,
    SocketEvent(0, Message(text)),
    test_emit,
    "unused",
  )
  assert_true(online.connection is Online)
  assert_eq(online.retry_attempt, 0)
  assert_true(online.replica.has_snapshot())
  assert_false(original.replica.has_snapshot())
  assert_false(original == online)
  let (reconnecting, _) = update(
    online,
    SocketEvent(0, Message("{")),
    test_emit,
    "unused",
  )
  assert_true(reconnecting.connection is Reconnecting)
  assert_false(reconnecting.replica.has_snapshot())
  assert_true(online.replica.has_snapshot())
}

///|
fn carded_task_json(id : String, stage : String) -> Json {
  {
    "id": id.to_json(),
    "title": ("Task " + id).to_json(),
    "description": "Read-only task",
    "stage": stage.to_json(),
    "priority": "normal",
    "definition_of_done": [],
    "dependencies": [],
    "created_at_ms": 1234,
    "updated_at_ms": 1234,
    "ready_since_ms": null,
  }
}

///|
test "reconnect after invalidation drops stale cards and waits again" {
  let model = Model::empty(true)
  let text = @protocol.encode_server_frame(
    Snapshot({
      protocol_version: 1,
      last_seq: 0L,
      board_revision: 1L,
      payload: {
        "board": {
          "revision": 1,
          "tasks": [carded_task_json("t", "ready")],
          "attempts": [],
        },
        "events": [],
      },
    }),
  )
  let (online, _) = update(
    model,
    SocketEvent(0, Message(text)),
    test_emit,
    "unused",
  )
  assert_true(online.connection is Online)
  assert_eq(empty_message(online.replica), None)
  assert_eq(tasks_in_lane(online.replica, Ready).length(), 1)
  let (resyncing, _) = update(
    online,
    SocketEvent(
      0,
      Message(
        @protocol.encode_server_frame(
          ResyncRequired(reason="client_queue_overflow", current_seq=0L),
        ),
      ),
    ),
    test_emit,
    "unused",
  )
  assert_true(resyncing.connection is Reconnecting)
  assert_false(resyncing.replica.has_snapshot())
  assert_eq(resyncing.replica.tasks().length(), 0)
  assert_eq(tasks_in_lane(resyncing.replica, Ready).length(), 0)
  assert_eq(empty_message(resyncing.replica), Some("Waiting for Board state"))
}

///|
test "protocol error is terminal and ignores socket close or delayed retry" {
  let original = Model::empty(true)
  let (terminal, _) = update(
    original,
    SocketEvent(
      0,
      Message(
        @protocol.encode_server_frame(
          Error(code="unsupported_version", message="must never appear in UI"),
        ),
      ),
    ),
    test_emit,
    "unused",
  )
  assert_true(terminal.connection is ProtocolError(_))
  assert_false(terminal.retry_pending)
  assert_false(terminal.last_status.contains("must never"))
  let (closed, _) = update(
    terminal,
    SocketEvent(0, Errored),
    test_emit,
    "unused",
  )
  assert_true(closed.connection is ProtocolError(_))
  assert_false(closed.retry_pending)
  let (retried, _) = update(closed, Retry(0), test_emit, "unused")
  assert_true(retried.connection is ProtocolError(_))
  assert_eq(retried.generation, 0)
}
