///|
/// A Review attempt record for authoritative snapshots. An empty review
/// string encodes the JSON null the decoder maps to no decision.
fn review_attempt_json(
  status : String,
  review : String,
  id~ : String = "a",
  task_id~ : String = "t",
  kind~ : String = "review",
) -> Json {
  {
    "id": Json(id),
    "task_id": Json(task_id),
    "kind": Json(kind),
    "status": Json(status),
    "review": if review == "" {
      Json::null()
    } else {
      Json(review)
    },
    "created_at_ms": 10,
    "started_at_ms": if status == "queued" {
      Json::null()
    } else {
      20
    },
    "finished_at_ms": if status == "queued" || status == "running" {
      Json::null()
    } else {
      30
    },
    "updated_at_ms": 30,
  }
}

///|
/// Seed an online model with one inspected task and one attempt whose kind,
/// status and review come from the caller.
fn review_model(
  status : String,
  review : String,
  kind~ : String = "review",
) -> Model {
  let replica = @client.BoardReplica::empty()
  guard replica.apply_text(
      inspector_snapshot(
        [dependency_task_json("t", []), dependency_task_json("b", [])],
        attempts=[review_attempt_json(status, review, kind~)],
      ),
    )
    is Applied else {
    abort("Invalid review test snapshot")
  }
  {
    ..Model::empty(true),
    replica,
    connection: Online,
    selected_task: Some("t"),
  }
}

///|
/// One authoritative `board.review.recorded` event replacing the attempt.
fn review_recorded_event(
  decision~ : String = "approved",
  review~ : String = "approved",
  status~ : String = "running",
  seq~ : Int64 = 1L,
  revision~ : Int64 = 2L,
  id~ : String = "a",
) -> String {
  @protocol.encode_server_frame(
    Event({
      seq,
      board_revision: revision,
      scope: None,
      kind: "board.review.recorded",
      payload: {
        "attempt_id": Json(id),
        "task_id": "t",
        "attempt": review_attempt_json(status, review, id~),
        "decision": Json(decision),
        "at_ms": 55,
      },
    }),
  )
}

///|
fn review_ready_to_confirm(env : Env) -> Model {
  let (model, _) = update(
    review_model("running", "pending"),
    ReviewDecide("a", "approved"),
    test_emit,
    env,
  )
  model
}

///|
fn submitted_review() -> Model {
  let (model, _) = update(
    review_ready_to_confirm(counting_env()),
    ConfirmAccepted,
    test_emit,
    counting_env(),
  )
  model
}

///|
test "review command schema rides the recordable decision enum only" {
  for
    (value, wire) in [
      ("approved", "approved"),
      ("changes_requested", "changes_requested"),
    ] {
    let draft : ReviewDraft = {
      task_id: "t",
      attempt_id: "a",
      decision: review_decision_from_wire(value),
    }
    let command = review_command(
      "uuid-9",
      4L,
      draft.attempt_id,
      draft.decision.unwrap(),
    )
    assert_eq(command.command_id, "cmd-uuid-9")
    assert_eq(command.name, "board.review.record")
    assert_eq(command.expected_revision, 4L)
    assert_eq(command.args, { "id": "a", "decision": wire })
    match @protocol.decode_client_frame(command_payload(command)) {
      Ok(Command(decoded)) => assert_eq(decoded, command)
      _ => fail("expected Command frame")
    }
  }
  // `pending` is the implicit running state, never a wire decision.
  assert_true(review_decision_from_wire("approved") is Some(Approved))
  assert_true(
    review_decision_from_wire("changes_requested") is Some(ChangesRequested),
  )
  for unknown in ["pending", "", "blocked"] {
    assert_true(review_decision_from_wire(unknown) is None)
  }
}

///|
test "one click decides approved through confirmation and never blind" {
  let model = review_model("running", "pending")
  let (decided, cmd) = update(
    model,
    ReviewDecide("a", "approved"),
    test_emit,
    counting_env(),
  )
  assert_true(
    decided.review_draft
    is Some({ task_id: "t", attempt_id: "a", decision: Some(Approved), }),
  )
  assert_true(decided.confirm is Some(ConfirmReview))
  // Nothing is sent and no identifier is consumed until confirmation.
  assert_true(decided.pending is None)
  debug_inspect(cmd, content="[]")
  // Any other wire value refuses to open the confirmation.
  for value in ["changes_requested", "pending", "", "secret"] {
    let (refused, cmd) = update(
      model,
      ReviewDecide("a", value),
      test_emit,
      test_env(),
    )
    assert_true(refused == model)
    debug_inspect(cmd, content="[]")
  }
  // Dismissing the confirmation drops the draft it created.
  let (dropped, _) = update(decided, ConfirmDismissed, test_emit, test_env())
  assert_true(dropped.review_draft is None)
  assert_true(dropped.confirm is None)
  assert_true(dropped.replica == model.replica)
}

///|
test "recording is eligible only for a running Review attempt still pending" {
  for kind in ["discuss", "execute", "review"] {
    for
      status in [
        "queued", "running", "succeeded", "failed", "cancelled", "interrupted",
      ] {
      for review in ["", "pending", "approved", "changes_requested"] {
        let model = review_model(status, review, kind~)
        let (after, _) = update(
          model,
          ReviewDecide("a", "approved"),
          test_emit,
          test_env(),
        )
        let expected = kind == "review" &&
          status == "running" &&
          review == "pending"
        assert_eq(after.review_draft is Some(_), expected)
        assert_eq(after.confirm is Some(_), expected)
      }
    }
  }
}

///|
test "review admission fails closed when offline unknown or misselected" {
  let model = review_model("running", "pending")
  for
    unavailable in [
      { ..model, connection: Offline, },
      { ..model, connection: Reconnecting, },
      { ..model, replica: @client.BoardReplica::empty(), },
      { ..model, selected_task: Some("b"), },
      { ..model, selected_task: None, },
    ] {
    let (blocked, cmd) = update(
      unavailable,
      ReviewDecide("a", "approved"),
      test_emit,
      test_env(),
    )
    assert_true(blocked == unavailable)
    debug_inspect(cmd, content="[]")
  }
  for id in ["missing", ""] {
    let (blocked, cmd) = update(
      model,
      ReviewDecide(id, "approved"),
      test_emit,
      test_env(),
    )
    assert_true(blocked == model)
    debug_inspect(cmd, content="[]")
  }
  // Deciding needs no identifier; only submission fails closed without one.
  let (submitted, cmd) = update(
    review_ready_to_confirm(test_env()),
    ConfirmAccepted,
    test_emit,
    missing_uuid_env(),
  )
  assert_true(submitted.pending is None)
  assert_true(
    submitted.review_draft == review_ready_to_confirm(test_env()).review_draft,
  )
  assert_true(submitted.notice is Some({ severity: Error, .. }))
  debug_inspect(cmd, content="[]")
  let (blank, cmd) = update(
    review_ready_to_confirm(test_env()),
    ConfirmAccepted,
    test_emit,
    { url: "unused", uuid: () => Some(""), },
  )
  assert_true(blank == submitted)
  debug_inspect(cmd, content="[]")
}

///|
test "the review confirmation survives browsing and close until dismissed" {
  let original = review_model("running", "pending")
  let (decided, _) = update(
    original,
    ReviewDecide("a", "approved"),
    test_emit,
    counting_env(),
  )
  let (switched, _) = update(decided, TaskSelected("b"), test_emit, test_env())
  assert_eq(switched.selected_task, Some("b"))
  assert_true(switched.review_draft == decided.review_draft)
  assert_true(switched.confirm == decided.confirm)
  let (closed, _) = update(switched, InspectorClosed, test_emit, test_env())
  assert_true(closed.selected_task is None)
  assert_true(closed.review_draft == decided.review_draft)
  assert_true(closed.replica == original.replica)
}

///|
test "every editor draft and pending command shares one admission gate with review" {
  let open_messages : Array[Msg] = [
    CreateOpened,
    EditOpened("t"),
    DependenciesOpened,
    MoveRequested("t", Running),
    AttemptQueueOpened,
    AttemptStartRequested("a"),
    AttemptFinishOpened("a"),
    ReviewDecide("a", "approved"),
  ]
  for
    model in [
      opened_queue(counting_env()),
      chosen_finish(),
      draft_model(),
      review_ready_to_confirm(counting_env()),
    ] {
    for msg in open_messages {
      let (blocked, command) = update(model, msg, test_emit, test_env())
      assert_true(blocked == model)
      debug_inspect(command, content="[]")
    }
  }
  let pending_messages : Array[Msg] = [
    ..open_messages,
    SubmitRequested,
    DependenciesSubmitted,
    AttemptQueueSubmitted,
    AttemptFinishSubmitted,
  ]
  for kind in ["queue", "start", "finish"] {
    for msg in pending_messages {
      let (blocked, cmd) = update(
        submitted_lifecycle(kind),
        msg,
        test_emit,
        test_env(),
      )
      assert_true(blocked == submitted_lifecycle(kind))
      debug_inspect(cmd, content="[]")
    }
  }
}

///|
test "one pending slot gates review controls and review gates every other editor" {
  let pending = submitted_review()
  for
    msg in [
      CreateOpened,
      EditOpened("t"),
      DependenciesOpened,
      MoveRequested("t", Running),
      AttemptQueueOpened,
      AttemptStartRequested("a"),
      AttemptFinishOpened("a"),
      ReviewDecide("a", "approved"),
    ] {
    let (blocked, cmd) = update(pending, msg, test_emit, test_env())
    assert_true(blocked == pending)
    debug_inspect(cmd, content="[]")
  }
  // With a pending command in flight, deciding again is parked too.
  let gated = {
    ..review_ready_to_confirm(counting_env()),
    pending: Some(pending_probe()),
  }
  let (parked, cmd) = update(
    gated,
    ReviewDecide("a", "approved"),
    test_emit,
    test_env(),
  )
  assert_true(parked == gated)
  debug_inspect(cmd, content="[]")
}

///|
test "submission reads the live revision and sends the correlated record command" {
  let env = counting_env()
  let (decided, _) = update(
    review_model("running", "pending"),
    ReviewDecide("a", "approved"),
    test_emit,
    env,
  )
  let (live, _) = update(
    decided,
    SocketEvent(0, Message(task_event_text("t", "ready", 1, 2))),
    test_emit,
    test_env(),
  )
  let (submitted, sent) = update(live, ConfirmAccepted, test_emit, env)
  let expected = @client.record_review_command(
    "cmd-uuid-1",
    2L,
    id="a",
    decision=@client.Approved,
  )
  assert_eq(
    Repr(sent).to_string(),
    Repr(send_command(0, expected, test_emit)).to_string(),
  )
  assert_true(
    submitted.pending
    is Some(
      {
        command_id: "cmd-uuid-1",
        revision: 2L,
        kind: PendingReview(attempt_id="a"),
      }
    ),
  )
  // No optimistic projection: the replica only changes from Board frames.
  assert_true(submitted.replica == live.replica)
  assert_true(
    attempt_by_id(submitted.replica, "a").unwrap().review is Some(Pending),
  )
}

///|
test "review events precede the exact correlated settlement without projection" {
  let pending = submitted_review()
  let before = pending.replica.copy()
  let (foreign, _) = update(
    pending,
    SocketEvent(
      0,
      Message(command_result_text("foreign", true, None, Some(1L))),
    ),
    test_emit,
    test_env(),
  )
  assert_true(foreign == pending)
  let (evented, _) = update(
    pending,
    SocketEvent(0, Message(review_recorded_event())),
    test_emit,
    test_env(),
  )
  assert_eq(evented.replica.revision(), 2L)
  assert_true(
    attempt_by_id(evented.replica, "a").unwrap().review is Some(Approved),
  )
  assert_true(evented.pending == pending.pending)
  assert_true(evented.review_draft == pending.review_draft)
  assert_true(pending.replica == before)
  let (settled, command) = update(
    evented,
    lifecycle_result(evented, true, None, Some(2L)),
    test_emit,
    test_env(),
  )
  assert_true(settled.pending is None)
  assert_true(settled.review_draft is None)
  assert_true(settled.replica == evented.replica)
  assert_true(settled.notice is Some({ severity: Success, .. }))
  assert_true(settled.notice.unwrap().text.has_prefix("Review decision saved."))
  debug_inspect(command, content="[]")
}

///|
test "accepted review result without its event forces an authoritative refresh" {
  let pending = submitted_review()
  let (settled, _) = update(
    pending,
    lifecycle_result(pending, true, None, Some(2L)),
    test_emit,
    test_env(),
  )
  assert_true(settled.pending is None)
  // The reported revision disagrees, so the veil comes up over the retained
  // board while the reconnect replays the missed frames.
  assert_true(settled.replica.has_snapshot())
  assert_true(settled.stale)
  assert_true(settled.retry_pending)
  assert_true(settled.review_draft is None)
  assert_true(
    settle_review_draft(
      review_ready_to_confirm(test_env()).review_draft,
      PendingAttemptFinish(attempt_id="a"),
    )
    is Some(_),
  )
  assert_true(
    settle_review_draft(
      review_ready_to_confirm(test_env()).review_draft,
      PendingReview(attempt_id="other"),
    )
    is Some(_),
  )
  assert_true(
    settle_review_draft(
      review_ready_to_confirm(test_env()).review_draft,
      PendingReview(attempt_id="a"),
    )
    is None,
  )
}

///|
test "review rejections map safe text and keep the draft without retries" {
  for
    code in [
      "invalid_review_transition", "attempt_not_found", "invalid_input", "invalid_arguments",
      "persistence_failed", "board_timeout", "board_initializing", "board_unavailable",
      "private-store-path",
    ] {
    let pending = submitted_review()
    let (rejected, command) = update(
      pending,
      lifecycle_result(pending, false, Some(code), Some(1L)),
      test_emit,
      test_env(),
    )
    assert_true(rejected.pending is None)
    assert_true(rejected.replica == pending.replica)
    assert_true(rejected.review_draft == pending.review_draft)
    assert_eq(rejected.notice.unwrap().text, rejection_text(Some(code)))
    assert_false(rejected.retry_pending)
    debug_inspect(command, content="[]")
  }
  assert_eq(
    rejection_text(Some("invalid_review_transition")),
    "The board does not allow this review decision from the attempt's current state.",
  )
}

///|
test "review conflict and stale revisions keep the board under the veil" {
  for
    code in ["revision_conflict", "durability_uncertain", "persistence_failed"] {
    let pending = submitted_review()
    let (stale, _) = update(
      pending,
      lifecycle_result(pending, false, Some(code), Some(2L)),
      test_emit,
      test_env(),
    )
    assert_true(stale.replica.has_snapshot())
    assert_true(stale.stale)
    assert_true(stale.pending is None)
    assert_true(stale.review_draft == pending.review_draft)
    let (retrying, _) = update(stale, Retry(0), test_emit, test_env())
    let (_, command) = update(
      retrying,
      SocketEvent(1, Opened),
      test_emit,
      test_env(),
    )
    assert_eq(
      Repr(command).to_string(),
      Repr(
        @rabbita.batch([
          @websocket.send("board", Text(hello_payload(stale.replica)), failed=_ => {
            test_emit(TransportFailed(1))
          }),
          @rabbita.delay(test_emit(ConnectionStable(1)), 1000),
        ]),
      ).to_string(),
    )
  }
}

///|
test "durability uncertainty keeps event authority when the revision matches" {
  let pending = submitted_review()
  let (evented, _) = update(
    pending,
    SocketEvent(0, Message(review_recorded_event())),
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
  assert_true(settled.review_draft == pending.review_draft)
  assert_true(settled.notice is Some({ severity: Warning, .. }))
  assert_false(settled.retry_pending)
  debug_inspect(command, content="[]")
}

///|
test "pending review delivery failures resync with Hello only and never replay" {
  let pending = submitted_review()
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
            ResyncRequired(reason="test", current_seq=1L),
          ),
        ),
      ),
    ] {
    let (lost, _) = update(pending, msg, test_emit, test_env())
    assert_true(lost.pending is None)
    assert_false(lost.replica.has_snapshot())
    assert_true(lost.review_draft == pending.review_draft)
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

///|
test "stale callbacks and terminal protocol errors never settle review commands" {
  let pending = { ..submitted_review(), generation: 3, }
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
            Some(1L),
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
  assert_true(terminal.review_draft == pending.review_draft)
  let (blocked, cmd) = update(terminal, Retry(3), test_emit, test_env())
  assert_true(blocked == terminal)
  debug_inspect(cmd, content="[]")
}

///|
test "external decisions and finishes disable the draft and a missing target closes it" {
  let draft = review_ready_to_confirm(counting_env())
  // An external authoritative decision consumes the record window.
  let (externally, _) = update(
    draft,
    SocketEvent(0, Message(review_recorded_event())),
    test_emit,
    test_env(),
  )
  assert_true(externally.review_draft == draft.review_draft)
  assert_false(
    review_draft_editable(externally, externally.review_draft.unwrap()),
  )
  // Accepting the confirmation then refuses to send anything.
  let (blocked, cmd) = update(
    externally,
    ConfirmAccepted,
    test_emit,
    test_env(),
  )
  assert_true(blocked.pending is None)
  assert_true(blocked.replica == externally.replica)
  assert_true(blocked.review_draft == externally.review_draft)
  debug_inspect(cmd, content="[]")
  // An external authoritative finish leaves the record window too.
  let (finished, _) = update(
    review_ready_to_confirm(counting_env()),
    SocketEvent(0, Message(lifecycle_event("cancelled"))),
    test_emit,
    test_env(),
  )
  assert_true(finished.review_draft is Some(_))
  assert_false(review_draft_editable(finished, finished.review_draft.unwrap()))
  // A replacement snapshot without the attempt closes the draft safely.
  let (missing, _) = update(
    draft,
    SocketEvent(
      0,
      Message(inspector_snapshot([dependency_task_json("t", [])], revision=2L)),
    ),
    test_emit,
    test_env(),
  )
  assert_true(missing.review_draft is None)
  assert_eq(missing.selected_task, Some("t"))
  assert_true(missing.notice is Some({ severity: Warning, .. }))
  // A replacement snapshot that still holds the pending attempt revalidates
  // the draft live instead of going stale.
  let chosen = review_ready_to_confirm(test_env())
  let (kept, _) = update(
    chosen,
    SocketEvent(
      0,
      Message(
        inspector_snapshot(
          [dependency_task_json("t", []), dependency_task_json("b", [])],
          attempts=[review_attempt_json("running", "pending")],
          revision=2L,
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  assert_true(kept.review_draft == chosen.review_draft)
  assert_true(review_submit_allowed(kept, kept.review_draft.unwrap()))
  assert_eq(attempt_by_id(kept.replica, "a").unwrap().updated_at_ms, 30L)
}

///|
test "finish warns for a pending review without blocking the attempt outcome" {
  let model = review_model("running", "pending")
  let attempt = attempt_by_id(model.replica, "a").unwrap()
  assert_true(finish_review_pending(attempt))
  assert_eq(
    finish_review_warning(attempt),
    Some(
      "Finishing now will leave this review without a recorded decision. A decision cannot be recorded after the attempt finishes.",
    ),
  )
  assert_true(review_recordable(attempt))
  let (opened, cmd) = update(
    model,
    AttemptFinishOpened("a"),
    test_emit,
    test_env(),
  )
  assert_true(opened.finish_draft is Some({ attempt_id: "a", .. }))
  debug_inspect(cmd, content="[]")
  let (chosen, _) = update(
    opened,
    AttemptOutcomeChanged("succeeded"),
    test_emit,
    test_env(),
  )
  assert_true(finish_submit_allowed(chosen, chosen.finish_draft.unwrap()))
  let env = counting_env()
  let (submitted, sent) = update(chosen, AttemptFinishSubmitted, test_emit, env)
  assert_true(
    submitted.pending
    is Some({ kind: PendingAttemptFinish(attempt_id="a"), .. }),
  )
  let expected = @client.finish_attempt_command(
    "cmd-uuid-1",
    1L,
    id="a",
    outcome=@client.Succeeded,
  )
  assert_eq(
    Repr(sent).to_string(),
    Repr(send_command(0, expected, test_emit)).to_string(),
  )
  // The warning is specific to a Running Review attempt still pending.
  for
    (status, review, kind, expected) in [
      ("running", "approved", "review", false),
      ("running", "changes_requested", "review", false),
      ("running", "pending", "execute", false),
      ("cancelled", "pending", "review", false),
    ] {
    let other = review_model(status, review, kind~)
    assert_eq(
      finish_review_pending(attempt_by_id(other.replica, "a").unwrap()),
      expected,
    )
    assert_eq(
      finish_review_warning(attempt_by_id(other.replica, "a").unwrap()),
      None,
    )
  }
}
