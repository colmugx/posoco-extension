///|
fn lifecycle_attempt(
  status : String,
  id? : String = "a",
  task_id? : String = "t",
) -> Json {
  {
    "id": id.to_json(),
    "task_id": task_id.to_json(),
    "kind": "execute",
    "status": status.to_json(),
    "review": null,
    "created_at_ms": 10,
    "started_at_ms": if status == "queued" {
      null
    } else {
      20
    },
    "finished_at_ms": if status == "queued" || status == "running" {
      null
    } else {
      30
    },
    "updated_at_ms": 30,
  }
}

///|
fn lifecycle_model(status : String) -> Model {
  let replica = @client.BoardReplica::empty()
  guard replica.apply_text(
      inspector_snapshot(
        [dependency_task_json("t", []), dependency_task_json("b", [])],
        attempts=[lifecycle_attempt(status)],
      ),
    )
    is Applied else {
    abort("Invalid lifecycle test snapshot")
  }
  {
    ..Model::empty(true),
    replica,
    connection: Online,
    selected_task: Some("t"),
  }
}

///|
fn lifecycle_event(
  status : String,
  seq? : Int64 = 1L,
  revision? : Int64 = 2L,
  id? : String = "a",
) -> String {
  @protocol.encode_server_frame(
    Event({
      seq,
      board_revision: revision,
      scope: None,
      kind: if status == "queued" {
        "board.attempt.queued"
      } else if status == "running" {
        "board.attempt.started"
      } else {
        "board.attempt.finished"
      },
      payload: {
        "attempt_id": id.to_json(),
        "task_id": "t",
        "attempt": lifecycle_attempt(status, id~),
      },
    }),
  )
}

///|
fn opened_queue(env : Env) -> Model {
  let (model, _) = update(
    lifecycle_model("queued"),
    AttemptQueueOpened,
    test_emit,
    env,
  )
  model
}

///|
fn opened_finish() -> Model {
  let (model, _) = update(
    lifecycle_model("running"),
    AttemptFinishOpened("a"),
    test_emit,
    test_env(),
  )
  model
}

///|
fn chosen_finish() -> Model {
  let (model, _) = update(
    opened_finish(),
    AttemptOutcomeChanged("cancelled"),
    test_emit,
    test_env(),
  )
  model
}

///|
fn submitted_lifecycle(kind : String) -> Model {
  let env = counting_env()
  let (model, _) = match kind {
    "queue" => update(opened_queue(env), AttemptQueueSubmitted, test_emit, env)
    "start" =>
      update(
        lifecycle_model("queued"),
        AttemptStartRequested("a"),
        test_emit,
        env,
      )
    _ => update(chosen_finish(), AttemptFinishSubmitted, test_emit, env)
  }
  model
}

///|
fn lifecycle_result(
  model : Model,
  accepted : Bool,
  error : String?,
  revision : Int64?,
) -> Msg {
  SocketEvent(
    model.generation,
    Message(
      command_result_text(
        model.pending.unwrap().command_id,
        accepted,
        error,
        revision,
      ),
    ),
  )
}

///|
test "queue draft uses an independent secure UUID and submit reads the live revision" {
  let env = counting_env()
  let original = lifecycle_model("queued")
  let (opened, command) = update(original, AttemptQueueOpened, test_emit, env)
  assert_true(opened.replica == original.replica)
  assert_eq(opened.attempt_draft.unwrap().attempt_id, "attempt-uuid-1")
  assert_true(opened.pending is None)
  debug_inspect(command, content="[]")
  let (changed, _) = update(
    opened,
    AttemptKindChanged("review"),
    test_emit,
    env,
  )
  assert_true(changed.attempt_draft.unwrap().kind is Review)
  let (live, _) = update(
    changed,
    SocketEvent(0, Message(lifecycle_event("running"))),
    test_emit,
    env,
  )
  let (submitted, sent) = update(live, AttemptQueueSubmitted, test_emit, env)
  let expected = @client.queue_attempt_command(
    "cmd-uuid-2",
    2L,
    id="attempt-uuid-1",
    task_id="t",
    kind=@client.Review,
  )
  assert_eq(
    Repr(sent).to_string(),
    Repr(send_command(0, expected, test_emit)).to_string(),
  )
  assert_true(
    submitted.pending
    is Some(
      {
        command_id: "cmd-uuid-2",
        revision: 2L,
        kind: PendingAttemptQueue(task_id="t", attempt_id="attempt-uuid-1"),
      }
    ),
  )
  assert_true(submitted.replica == live.replica)
  assert_eq(submitted.replica.attempts().length(), 1)
  let (unknown, _) = update(
    changed,
    AttemptKindChanged("private-value"),
    test_emit,
    env,
  )
  assert_true(unknown == changed)
}

///|
test "finish starts without a terminal choice and sends the explicit chosen outcome" {
  let opened = opened_finish()
  assert_true(opened.finish_draft.unwrap().outcome is None)
  let (blocked, command) = update(
    opened,
    AttemptFinishSubmitted,
    test_emit,
    test_env(),
  )
  assert_true(blocked == opened)
  debug_inspect(command, content="[]")
  for value in ["succeeded", "failed", "cancelled", "interrupted"] {
    let (chosen, _) = update(
      opened,
      AttemptOutcomeChanged(value),
      test_emit,
      test_env(),
    )
    assert_eq(chosen.finish_draft.unwrap().outcome.unwrap().to_wire(), value)
    let (pending, sent) = update(
      chosen,
      AttemptFinishSubmitted,
      test_emit,
      test_env(),
    )
    let expected = @client.finish_attempt_command(
      "cmd-uuid-1",
      1L,
      id="a",
      outcome=chosen.finish_draft.unwrap().outcome.unwrap(),
    )
    assert_eq(
      Repr(sent).to_string(),
      Repr(send_command(0, expected, test_emit)).to_string(),
    )
    assert_true(pending.replica == opened.replica)
    assert_true(
      pending.pending
      is Some({ kind: PendingAttemptFinish(attempt_id="a"), .. }),
    )
  }
  let (unknown, _) = update(
    opened,
    AttemptOutcomeChanged("running"),
    test_emit,
    test_env(),
  )
  assert_true(unknown == opened)
  let (reset, _) = update(
    chosen_finish(),
    AttemptOutcomeChanged(""),
    test_emit,
    test_env(),
  )
  assert_true(reset.finish_draft.unwrap().outcome is None)
}

///|
test "start emits only its live attempt id with the current authoritative revision" {
  let original = lifecycle_model("queued")
  let (live, _) = update(
    original,
    SocketEvent(0, Message(task_event_text("t", "ready", 1, 2))),
    test_emit,
    test_env(),
  )
  let (pending, command) = update(
    live,
    AttemptStartRequested("a"),
    test_emit,
    test_env(),
  )
  assert_true(pending.replica == live.replica)
  assert_true(
    pending.pending
    is Some({ revision: 2L, kind: PendingAttemptStart(attempt_id="a"), .. }),
  )
  assert_eq(
    Repr(command).to_string(),
    Repr(
      send_command(
        0,
        @client.start_attempt_command("cmd-uuid-1", 2L, id="a"),
        test_emit,
      ),
    ).to_string(),
  )
}

///|
test "manual start and finish reject stale IDs task selections and invalid statuses" {
  for
    status in [
      "queued", "running", "succeeded", "failed", "cancelled", "interrupted",
    ] {
    let model = lifecycle_model(status)
    let (started, _) = update(
      model,
      AttemptStartRequested("a"),
      test_emit,
      test_env(),
    )
    assert_eq(started.pending is Some(_), status == "queued")
    let (finish, _) = update(
      model,
      AttemptFinishOpened("a"),
      test_emit,
      test_env(),
    )
    assert_eq(finish.finish_draft is Some(_), status == "running")
    for id in ["missing", ""] {
      let (blocked, cmd) = update(
        model,
        AttemptStartRequested(id),
        test_emit,
        test_env(),
      )
      assert_true(blocked == model)
      debug_inspect(cmd, content="[]")
      let (blocked, _) = update(
        model,
        AttemptFinishOpened(id),
        test_emit,
        test_env(),
      )
      assert_true(blocked == model)
    }
    let other = { ..model, selected_task: Some("b"), }
    let (blocked, _) = update(
      other,
      AttemptStartRequested("a"),
      test_emit,
      test_env(),
    )
    assert_true(blocked == other)
    let (blocked, _) = update(
      other,
      AttemptFinishOpened("a"),
      test_emit,
      test_env(),
    )
    assert_true(blocked == other)
  }
}

///|
test "queue and finish drafts survive browsing and explicit dismissal without projecting" {
  for original in [opened_queue(counting_env()), chosen_finish()] {
    let (switched, _) = update(
      original,
      TaskSelected("b"),
      test_emit,
      test_env(),
    )
    let (closed, _) = update(switched, InspectorClosed, test_emit, test_env())
    assert_true(closed.attempt_draft == original.attempt_draft)
    assert_true(closed.finish_draft == original.finish_draft)
    let (blocked, command) = update(
      closed,
      AttemptQueueSubmitted,
      test_emit,
      test_env(),
    )
    assert_true(blocked == closed)
    debug_inspect(command, content="[]")
    let (blocked, _) = update(
      closed,
      AttemptFinishSubmitted,
      test_emit,
      test_env(),
    )
    assert_true(blocked == closed)
    let (returned, _) = update(
      closed,
      AttemptDraftReturned,
      test_emit,
      test_env(),
    )
    assert_eq(returned.selected_task, Some("t"))
    let (cancelled, _) = update(
      returned,
      if original.attempt_draft is Some(_) {
        AttemptQueueCancelled
      } else {
        AttemptFinishCancelled
      },
      test_emit,
      test_env(),
    )
    assert_true(
      cancelled.attempt_draft is None && cancelled.finish_draft is None,
    )
    assert_true(cancelled.replica == original.replica)
  }
}

///|
test "every editor and attempt mutation shares one draft and pending admission gate" {
  let messages : Array[Msg] = [
    CreateOpened,
    EditOpened("t"),
    DependenciesOpened,
    MoveRequested("t", Running),
    AttemptQueueOpened,
    AttemptStartRequested("a"),
    AttemptFinishOpened("a"),
  ]
  for model in [opened_queue(counting_env()), chosen_finish(), draft_model()] {
    for msg in messages {
      let (blocked, command) = update(model, msg, test_emit, test_env())
      assert_true(blocked == model)
      debug_inspect(command, content="[]")
    }
  }
  for kind in ["queue", "start", "finish"] {
    let pending = submitted_lifecycle(kind)
    for
      msg in [
        ..messages,
        AttemptKindChanged("execute"),
        AttemptOutcomeChanged("succeeded"),
        AttemptQueueSubmitted,
        AttemptFinishSubmitted,
        AttemptQueueCancelled,
        AttemptFinishCancelled,
      ] {
      let (blocked, cmd) = update(pending, msg, test_emit, test_env())
      assert_true(blocked == pending)
      debug_inspect(cmd, content="[]")
    }
  }
}

///|
test "attempt admission fails closed when offline unknown or crypto is unavailable" {
  let model = lifecycle_model("queued")
  for
    unavailable in [
      { ..model, connection: Offline, },
      { ..model, connection: Reconnecting, },
      { ..model, replica: @client.BoardReplica::empty(), },
    ] {
    for
      msg in [
        AttemptQueueOpened,
        AttemptStartRequested("a"),
        AttemptFinishOpened("a"),
      ] {
      let (blocked, cmd) = update(unavailable, msg, test_emit, test_env())
      assert_true(blocked == unavailable)
      debug_inspect(cmd, content="[]")
    }
  }
  for env in [missing_uuid_env(), { url: "unused", uuid: () => Some(""), }] {
    for
      (model, msg) in [
        (model, AttemptQueueOpened),
        (model, AttemptStartRequested("a")),
        (chosen_finish(), AttemptFinishSubmitted),
        (opened_queue(counting_env()), AttemptQueueSubmitted),
      ] {
      let (blocked, cmd) = update(model, msg, test_emit, env)
      assert_true(blocked.pending is None)
      assert_true(blocked.replica == model.replica)
      assert_true(blocked.notice is Some({ severity: Error, .. }))
      debug_inspect(cmd, content="[]")
    }
  }
}

///|
test "live duplicate queue id and external terminal status block draft submission" {
  let queue = opened_queue(counting_env())
  let (duplicate, _) = update(
    queue,
    SocketEvent(0, Message(lifecycle_event("queued", id="attempt-uuid-1"))),
    test_emit,
    test_env(),
  )
  assert_false(
    attempt_queue_submit_allowed(duplicate, duplicate.attempt_draft.unwrap()),
  )
  let (blocked, cmd) = update(
    duplicate,
    AttemptQueueSubmitted,
    test_emit,
    test_env(),
  )
  assert_true(blocked == duplicate)
  debug_inspect(cmd, content="[]")
  let finish = chosen_finish()
  let (terminal, _) = update(
    finish,
    SocketEvent(0, Message(lifecycle_event("interrupted"))),
    test_emit,
    test_env(),
  )
  assert_true(terminal.finish_draft == finish.finish_draft)
  assert_false(finish_submit_allowed(terminal, terminal.finish_draft.unwrap()))
  let (blocked, cmd) = update(
    terminal,
    AttemptFinishSubmitted,
    test_emit,
    test_env(),
  )
  assert_true(blocked == terminal)
  debug_inspect(cmd, content="[]")
}

///|
test "attempt events precede exact correlated settlements without optimistic projection" {
  for kind in ["queue", "start", "finish"] {
    let pending = submitted_lifecycle(kind)
    let before = pending.replica.copy()
    let (foreign, _) = update(
      pending,
      SocketEvent(
        0,
        Message(command_result_text("foreign", true, None, Some(2L))),
      ),
      test_emit,
      test_env(),
    )
    assert_true(foreign == pending)
    let event = match kind {
      "queue" => lifecycle_event("queued", id="attempt-uuid-1")
      "start" => lifecycle_event("running")
      _ => lifecycle_event("cancelled")
    }
    let (evented, _) = update(
      pending,
      SocketEvent(0, Message(event)),
      test_emit,
      test_env(),
    )
    assert_eq(evented.replica.revision(), 2L)
    assert_true(evented.pending == pending.pending)
    assert_true(pending.replica == before)
    let (settled, command) = update(
      evented,
      lifecycle_result(evented, true, None, Some(2L)),
      test_emit,
      test_env(),
    )
    assert_true(settled.pending is None)
    assert_true(settled.attempt_draft is None && settled.finish_draft is None)
    assert_true(settled.replica == evented.replica)
    assert_true(settled.notice is Some({ severity: Success, .. }))
    debug_inspect(command, content="[]")
  }
}

///|
test "matching accepted attempt result without its event forces an authoritative refresh" {
  for kind in ["queue", "start", "finish"] {
    let pending = submitted_lifecycle(kind)
    let (settled, _) = update(
      pending,
      lifecycle_result(pending, true, None, Some(2L)),
      test_emit,
      test_env(),
    )
    assert_true(settled.pending is None)
    assert_false(settled.replica.has_snapshot())
    assert_true(settled.retry_pending)
    assert_true(settled.attempt_draft is None && settled.finish_draft is None)
  }
}

///|
test "attempt stable rejections retain drafts and map safe notices without retries" {
  for kind in ["queue", "start", "finish"] {
    for
      code in [
        "attempt_not_found", "duplicate_attempt", "invalid_attempt_transition", "task_not_found",
        "persistence_failed", "board_timeout", "board_initializing", "board_unavailable",
        "invalid_arguments", "invalid_input", "private-store-path",
      ] {
      let pending = submitted_lifecycle(kind)
      let (rejected, command) = update(
        pending,
        lifecycle_result(pending, false, Some(code), Some(1L)),
        test_emit,
        test_env(),
      )
      assert_true(rejected.pending is None)
      assert_true(rejected.replica == pending.replica)
      assert_true(rejected.attempt_draft == pending.attempt_draft)
      assert_true(rejected.finish_draft == pending.finish_draft)
      assert_eq(rejected.notice.unwrap().text, rejection_text(Some(code)))
      assert_false(rejected.retry_pending)
      debug_inspect(command, content="[]")
    }
  }
}

///|
test "attempt conflict and stale revisions refresh without replay and keep local drafts" {
  for kind in ["queue", "start", "finish"] {
    for
      code in [
        "revision_conflict", "invalid_attempt_transition", "durability_uncertain",
        "persistence_failed",
      ] {
      let pending = submitted_lifecycle(kind)
      let (stale, _) = update(
        pending,
        lifecycle_result(pending, false, Some(code), Some(2L)),
        test_emit,
        test_env(),
      )
      assert_false(stale.replica.has_snapshot())
      assert_true(stale.pending is None)
      assert_true(
        stale.attempt_draft == pending.attempt_draft &&
        stale.finish_draft == pending.finish_draft,
      )
      let (retrying, _) = update(stale, Retry(0), test_emit, test_env())
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
      assert_true(opened.pending is None)
    }
  }
}

///|
test "durability uncertainty preserves event authority when its revision matches" {
  for kind in ["queue", "start", "finish"] {
    let pending = submitted_lifecycle(kind)
    let event = if kind == "queue" {
      lifecycle_event("queued", id="attempt-uuid-1")
    } else {
      lifecycle_event("interrupted")
    }
    let (evented, _) = update(
      pending,
      SocketEvent(0, Message(event)),
      test_emit,
      test_env(),
    )
    let (settled, command) = update(
      evented,
      lifecycle_result(evented, false, Some("durability_uncertain"), Some(2L)),
      test_emit,
      test_env(),
    )
    assert_true(settled.pending is None)
    assert_true(settled.replica == evented.replica)
    assert_true(
      settled.attempt_draft == pending.attempt_draft &&
      settled.finish_draft == pending.finish_draft,
    )
    assert_true(settled.notice is Some({ severity: Warning, .. }))
    assert_false(settled.retry_pending)
    debug_inspect(command, content="[]")
  }
}

///|
test "pending attempt delivery failures reconcile with Hello only and retain drafts" {
  for kind in ["queue", "start", "finish"] {
    let pending = submitted_lifecycle(kind)
    for
      msg in [
        TransportFailed(0),
        SendFailed(0, pending.pending.unwrap().command_id),
        SocketEvent(0, Errored),
        SocketEvent(0, Message("{")),
        SocketEvent(
          0,
          Message(
            @protocol.encode_server_frame(
              ResyncRequired(reason="test", current_seq=2L),
            ),
          ),
        ),
      ] {
      let (lost, _) = update(pending, msg, test_emit, test_env())
      assert_true(lost.pending is None)
      assert_false(lost.replica.has_snapshot())
      assert_true(
        lost.attempt_draft == pending.attempt_draft &&
        lost.finish_draft == pending.finish_draft,
      )
      let (retrying, _) = update(lost, Retry(0), test_emit, test_env())
      let (_, command) = update(
        retrying,
        SocketEvent(1, Opened),
        test_emit,
        test_env(),
      )
      assert_eq(
        Repr(command).to_string(),
        Repr(
          @websocket.send(
            "board",
            Text(hello_payload(@client.BoardReplica::empty())),
            failed=_ => test_emit(TransportFailed(1)),
          ),
        ).to_string(),
      )
    }
  }
}

///|
test "stale callbacks and terminal protocol errors never replay pending attempts" {
  for kind in ["queue", "start", "finish"] {
    let pending = { ..submitted_lifecycle(kind), generation: 3, }
    for
      msg in [
        SendFailed(2, pending.pending.unwrap().command_id),
        SendFailed(3, "foreign"),
        TransportFailed(2),
        SocketEvent(2, Errored),
        SocketEvent(
          2,
          Message(
            command_result_text(
              pending.pending.unwrap().command_id,
              true,
              None,
              Some(2L),
            ),
          ),
        ),
      ] {
      let (unchanged, cmd) = update(pending, msg, test_emit, test_env())
      assert_true(unchanged == pending)
      debug_inspect(cmd, content="[]")
    }
    let (terminal, _) = update(
      pending,
      SocketEvent(
        3,
        Message(
          @protocol.encode_server_frame(
            Error(code="bad_version", message="private detail"),
          ),
        ),
      ),
      test_emit,
      test_env(),
    )
    assert_true(terminal.connection is ProtocolError(_))
    assert_true(terminal.pending is None)
    assert_false(terminal.replica.has_snapshot())
    assert_true(
      terminal.attempt_draft == pending.attempt_draft &&
      terminal.finish_draft == pending.finish_draft,
    )
    let (blocked, cmd) = update(terminal, Retry(3), test_emit, test_env())
    assert_true(blocked == terminal)
    debug_inspect(cmd, content="[]")
  }
}

///|
test "authoritative replacement revalidates attempt drafts without dropping pending correlation" {
  for kind in ["queue", "finish"] {
    let pending = submitted_lifecycle(kind)
    let (missing, _) = update(
      pending,
      SocketEvent(
        0,
        Message(
          inspector_snapshot([dependency_task_json("b", [])], revision=2L),
        ),
      ),
      test_emit,
      test_env(),
    )
    assert_true(missing.selected_task is None)
    assert_true(missing.attempt_draft is None && missing.finish_draft is None)
    assert_true(missing.pending == pending.pending)
    let (settled, _) = update(
      missing,
      lifecycle_result(missing, false, Some("attempt_not_found"), Some(2L)),
      test_emit,
      test_env(),
    )
    assert_true(settled.pending is None)
  }
  let model = chosen_finish()
  let (missing, _) = update(
    model,
    SocketEvent(
      0,
      Message(inspector_snapshot([dependency_task_json("t", [])], revision=2L)),
    ),
    test_emit,
    test_env(),
  )
  assert_eq(missing.selected_task, Some("t"))
  assert_true(missing.finish_draft is None)
}

///|
test "recovered Interrupted snapshot blocks an unconfirmed finish and never replays it" {
  let pending = submitted_lifecycle("finish")
  let (lost, _) = update(pending, TransportFailed(0), test_emit, test_env())
  assert_false(lost.replica.has_snapshot())
  assert_true(lost.finish_draft == pending.finish_draft)
  let (retrying, _) = update(lost, Retry(0), test_emit, test_env())
  let snapshot = inspector_snapshot(
    [carded_task_json("t", "suspended"), carded_task_json("b", "ready")],
    attempts=[lifecycle_attempt("interrupted")],
    revision=3L,
  )
  let (recovered, command) = update(
    retrying,
    SocketEvent(1, Message(snapshot)),
    test_emit,
    test_env(),
  )
  assert_true(recovered.pending is None)
  assert_true(recovered.connection is Online)
  assert_eq(recovered.replica.revision(), 3L)
  assert_eq(recovered.replica.last_seq(), 0L)
  assert_true(
    attempt_by_id(recovered.replica, "a").unwrap().status is Interrupted,
  )
  assert_eq(
    attempt_by_id(recovered.replica, "a").unwrap().finished_at_ms,
    Some(30L),
  )
  assert_true(recovered.finish_draft == pending.finish_draft)
  assert_false(
    finish_submit_allowed(recovered, recovered.finish_draft.unwrap()),
  )
  debug_inspect(command, content="[]")
  let (blocked, command) = update(
    recovered,
    AttemptFinishSubmitted,
    test_emit,
    test_env(),
  )
  assert_true(blocked == recovered)
  debug_inspect(command, content="[]")
  let (late, _) = update(
    recovered,
    SocketEvent(
      0,
      Message(
        command_result_text(
          pending.pending.unwrap().command_id,
          true,
          None,
          Some(2L),
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  assert_true(late == recovered)
}

///|
test "ordinary attempt draft reconnect preserves baseline and only sends baseline aware Hello" {
  for model in [opened_queue(counting_env()), chosen_finish()] {
    let (lost, _) = update(model, TransportFailed(0), test_emit, test_env())
    assert_true(lost.replica == model.replica)
    assert_true(
      lost.attempt_draft == model.attempt_draft &&
      lost.finish_draft == model.finish_draft,
    )
    let (retrying, _) = update(lost, Retry(0), test_emit, test_env())
    let (opened, command) = update(
      retrying,
      SocketEvent(1, Opened),
      test_emit,
      test_env(),
    )
    assert_true(opened.connection is Online)
    assert_eq(
      Repr(command).to_string(),
      Repr(
        @websocket.send("board", Text(hello_payload(model.replica)), failed=_ => {
          test_emit(TransportFailed(1))
        }),
      ).to_string(),
    )
  }
}

///|
test "accepted attempt settlement closes only the producing target draft" {
  let queue = opened_queue(counting_env()).attempt_draft.unwrap()
  assert_true(
    settle_attempt_draft(
      Some(queue),
      PendingAttemptQueue(task_id="other", attempt_id=queue.attempt_id),
    )
    is Some(_),
  )
  assert_true(
    settle_attempt_draft(
      Some(queue),
      PendingAttemptQueue(task_id="t", attempt_id="other"),
    )
    is Some(_),
  )
  assert_true(
    settle_attempt_draft(
      Some(queue),
      PendingAttemptStart(attempt_id=queue.attempt_id),
    )
    is Some(_),
  )
  assert_true(
    settle_attempt_draft(
      Some(queue),
      PendingAttemptQueue(task_id="t", attempt_id=queue.attempt_id),
    )
    is None,
  )
  let finish = chosen_finish().finish_draft.unwrap()
  assert_true(
    settle_finish_draft(Some(finish), PendingAttemptFinish(attempt_id="other"))
    is Some(_),
  )
  assert_true(
    settle_finish_draft(Some(finish), PendingAttemptStart(attempt_id="a"))
    is Some(_),
  )
  assert_true(
    settle_finish_draft(Some(finish), PendingAttemptFinish(attempt_id="a"))
    is None,
  )
}
