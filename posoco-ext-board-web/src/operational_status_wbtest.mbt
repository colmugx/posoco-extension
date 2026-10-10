///|
fn status_attempt_json(
  id : String,
  status : String,
  created_at_ms : Int,
) -> Json {
  {
    "id": id.to_json(),
    "task_id": "t".to_json(),
    "kind": "execute".to_json(),
    "status": status.to_json(),
    "review": null,
    "created_at_ms": created_at_ms.to_json(),
    "started_at_ms": null,
    "finished_at_ms": null,
    "updated_at_ms": created_at_ms.to_json(),
  }
}

///|
fn status_board(attempts : Array[Json]) -> @client.BoardReplica {
  let replica = @client.BoardReplica::empty()
  guard replica.apply_text(
      inspector_snapshot([carded_task_json("t", "ready")], attempts~),
    )
    is Applied else {
    abort("Invalid status test snapshot")
  }
  replica
}

///|
test "first snapshot status distinguishes the initial load" {
  let model = Model::empty(true)
  assert_eq(status_text(model), "Waiting for Board snapshot")
  assert_true(model.baseline is AwaitingFirst)
  let (opened, _) = update(model, SocketEvent(0, Opened), test_emit, test_env())
  // A bare open is not a snapshot and never claims Online.
  assert_true(opened.connection is Connecting)
  assert_true(opened.baseline is AwaitingFirst)
  assert_eq(status_text(opened), "Waiting for the first authoritative snapshot")
  let (loaded, _) = update(
    opened,
    SocketEvent(
      0,
      Message(snapshot_text(Json::array([carded_task_json("t", "ready")]), 1)),
    ),
    test_emit,
    test_env(),
  )
  assert_true(loaded.connection is Online)
  assert_true(loaded.baseline is Confirmed)
  assert_eq(status_text(loaded), "Authoritative Board state")
}

///|
test "retained baseline reconnect stays Reconnecting while disconnected and explains the idle open" {
  let original = draft_model()
  let (lost, _) = update(
    original,
    SocketEvent(0, Errored),
    test_emit,
    test_env(),
  )
  assert_true(lost.connection is Reconnecting)
  assert_true(lost.baseline is Retained)
  assert_true(lost.replica.has_snapshot())
  assert_eq(
    status_text(lost),
    "Reconnecting; the retained Board baseline stays and replays on reconnect",
  )
  assert_true(lost.dependency_editor == original.dependency_editor)
  let (retrying, _) = update(lost, Retry(0), test_emit, test_env())
  // Prior baseline alone never labels a disconnected retry Online.
  assert_true(retrying.connection is Reconnecting)
  let (opened, _) = update(
    retrying,
    SocketEvent(1, Opened),
    test_emit,
    test_env(),
  )
  // The socket is genuinely open, so Online is correct — and the status
  // explains that an up-to-date baseline may replay nothing at all.
  assert_true(opened.connection is Online)
  assert_true(opened.baseline is Retained)
  assert_eq(
    status_text(opened),
    "Board baseline retained; the open connection replays only missed changes",
  )
  // The draft survives the whole retained-baseline recovery.
  assert_true(opened.dependency_editor == original.dependency_editor)
}

///|
test "invalidated baseline reconnect discards state and requests a fresh snapshot" {
  let env = test_env()
  let (pending, _) = update(
    seeded_online("t", "ready"),
    MoveRequested("t", Running),
    test_emit,
    env,
  )
  let (lost, _) = update(
    pending,
    SendFailed(0, pending.pending.unwrap().command_id),
    test_emit,
    env,
  )
  assert_true(lost.connection is Reconnecting)
  assert_true(lost.baseline is Invalidated)
  assert_false(lost.replica.has_snapshot())
  assert_eq(
    status_text(lost),
    "Reconnecting; the stale Board baseline was discarded for a fresh snapshot",
  )
  let (retrying, _) = update(lost, Retry(0), test_emit, test_env())
  let (opened, _) = update(
    retrying,
    SocketEvent(1, Opened),
    test_emit,
    test_env(),
  )
  // An invalidated baseline is not retained: the open socket stays waiting.
  assert_true(opened.connection is Reconnecting)
  assert_eq(status_text(opened), "Waiting for a fresh authoritative snapshot")
  let (fresh, _) = update(
    opened,
    SocketEvent(
      1,
      Message(snapshot_text(Json::array([carded_task_json("t", "ready")]), 5)),
    ),
    test_emit,
    test_env(),
  )
  assert_true(fresh.connection is Online)
  assert_true(fresh.baseline is Confirmed)
  assert_eq(status_text(fresh), "Authoritative Board state")
}

///|
test "pending and terminal states own the status line with safe text" {
  let submitted = submitted_dependencies()
  assert_eq(
    status_text(submitted),
    "Saving change; waiting for authoritative confirmation.",
  )
  let terminal_frame = @protocol.encode_server_frame(
    Error(code="unsupported_version", message="must never appear in UI"),
  )
  let (terminal, _) = update(
    Model::empty(true),
    SocketEvent(0, Message(terminal_frame)),
    test_emit,
    test_env(),
  )
  assert_eq(
    status_text(terminal),
    "Board protocol error; automatic reconnect stopped",
  )
  // Uncertain durability keeps the existing mapped notice and the baseline
  // status; no protocol detail leaks into either surface.
  let (uncertain, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-1",
          false,
          Some("durability_uncertain"),
          Some(1L),
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  // The uncertain result keeps the baseline (and its status text) and the
  // existing mapped warning notice.
  assert_eq(uncertain.last_status, submitted.last_status)
  assert_true(uncertain.notice is Some({ severity: Warning, .. }))
  assert_eq(
    uncertain.notice.unwrap().text,
    "The board could not confirm whether this change was saved. The current board state is kept.",
  )
}

///|
test "attempt indicator never shows a naked running and breaks ties by id" {
  // No attempts at all.
  assert_eq(attempt_indicator(status_board([]), "t"), "No attempts")
  // A created_at_ms tie resolves by ID in both insertion orders.
  let tied = status_board([
    status_attempt_json("attempt-b", "succeeded", 20),
    status_attempt_json("attempt-a", "queued", 20),
  ])
  assert_eq(attempt_indicator(tied, "t"), "Latest attempt: Succeeded")
  let reversed = status_board([
    status_attempt_json("attempt-a", "queued", 20),
    status_attempt_json("attempt-b", "succeeded", 20),
  ])
  assert_eq(attempt_indicator(reversed, "t"), attempt_indicator(tied, "t"))
  // A running attempt is spelled out, never a bare "Running", and it
  // outranks a newer terminal attempt.
  let running = status_board([
    status_attempt_json("attempt-old", "running", 5),
    status_attempt_json("attempt-new", "succeeded", 30),
  ])
  assert_eq(attempt_indicator(running, "t"), "Attempt: Running (manual)")
  assert_eq(attempt_indicator(running, "missing"), "No attempts")
}
