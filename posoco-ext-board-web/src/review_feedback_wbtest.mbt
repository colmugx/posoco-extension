///|
/// A Review-stage task JSON with an optional durable reviewer feedback note, so
/// one fixture drives both the feedback editor and the feedback rendering.
fn feedback_task_json(feedback : Json) -> Json {
  {
    "id": "t",
    "title": "Title t",
    "description": "Task details",
    "stage": "review",
    "priority": "high",
    "definition_of_done": ["Tests pass"],
    "dependencies": Json::array([]),
    "created_at_ms": 10,
    "updated_at_ms": 20,
    "ready_since_ms": 11,
    "review_feedback": feedback,
  }
}

///|
/// Online Board model with one inspected Review task whose running Review
/// attempt is still pending a decision, plus an advertised ticket runtime.
fn feedback_model(feedback : Json) -> Model {
  let replica = @client.BoardReplica::empty()
  guard replica.apply_text(
      inspector_snapshot(
        [feedback_task_json(feedback), dependency_task_json("b", [])],
        attempts=[review_attempt_json("running", "pending")],
      ),
    )
    is Applied else {
    abort("Invalid request changes test snapshot")
  }
  {
    ..Model::empty(true),
    replica,
    connection: Online,
    selected_task: Some("t"),
    ticket_available: true,
  }
}

///|
/// Open the feedback editor on the inspected ticket and type one note.
fn feedback_typed(model : Model, feedback : String) -> Model {
  let (opened, _) = update(
    model,
    RequestChangesOpened("t"),
    test_emit,
    test_env(),
  )
  let (typed, _) = update(
    opened,
    RequestChangesFeedbackChanged(feedback),
    test_emit,
    test_env(),
  )
  typed
}

///|
fn feedback_json_field(value : Json, name : String) -> Json? {
  match value {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
test "request changes travels as a ticket command with the task id and the note" {
  let frame = @json.parse(
    ticket_command_frame(
      "board.ticket.request_changes",
      ticket_request_changes_args("t", "  Add a regression test.\n"),
    ),
  ) catch {
    _ => abort("the request changes frame must encode as JSON")
  }
  assert_eq(
    feedback_json_field(frame, "type"),
    Some(Json::string("ticket_command")),
  )
  assert_eq(
    feedback_json_field(frame, "name"),
    Some(Json::string("board.ticket.request_changes")),
  )
  match feedback_json_field(frame, "args") {
    Some(Object(args)) => {
      assert_eq(args.get("task_id"), Some(Json::string("t")))
      // The note is the reason for the round, so it travels trimmed and never
      // carries the attempt identity the old review decision used.
      assert_eq(
        args.get("feedback"),
        Some(Json::string("Add a regression test.")),
      )
      assert_eq(args.get("id"), None)
    }
    _ => fail("a request changes command must carry object arguments")
  }
}

///|
test "submitting request changes sends the note once and keeps the draft parked" {
  let model = feedback_model(Json::null())
  let typed = feedback_typed(model, "  Add a regression test.  ")
  assert_true(
    typed.request_changes_draft
    is Some({ task_id: "t", feedback: "  Add a regression test.  ", }),
  )
  // Opening and typing never touch the board: the replica is untouched.
  assert_true(typed.replica == model.replica)
  let (sent, _) = update(typed, RequestChangesSubmitted, test_emit, test_env())
  assert_true(sent.ticket_sending)
  assert_eq(sent.last_status, "Sending feedback for ticket t")
  // The draft survives submission so a rejection can be retried verbatim.
  assert_true(sent.request_changes_draft == typed.request_changes_draft)
  assert_true(sent.replica == typed.replica)
  let (rejected, _) = update(
    sent,
    TicketResult(false, Some("ticket is already running"), None),
    test_emit,
    test_env(),
  )
  assert_false(rejected.ticket_sending)
  assert_true(rejected.request_changes_draft == typed.request_changes_draft)
  assert_true(rejected.notice is Some({ severity: Warning, .. }))
  // The host moves the ticket Review → Ready, so the note now lives on the
  // ticket and the editor closes with the stage it belongs to.
  let (moved, _) = update(
    sent,
    SocketEvent(0, Message(task_event_text("t", "ready", 1, 2))),
    test_emit,
    test_env(),
  )
  assert_true(task_by_id(moved.replica, "t").unwrap().stage is Ready)
  assert_true(moved.request_changes_draft is None)
}

///|
test "request changes submit is disabled while sending disconnected unavailable or blank" {
  let model = feedback_model(Json::null())
  assert_false(ticket_request_changes_blocked(model, "Add a regression test."))
  for
    candidate in [
      { ..model, ticket_sending: true, },
      { ..model, can_connect: false, },
      { ..model, ticket_available: false, },
    ] {
    assert_true(
      ticket_request_changes_blocked(candidate, "Add a regression test."),
    )
    assert_true(
      ticket_request_changes_hint(candidate, "Add a regression test.")
      is Some(_),
    )
  }
  // A blank or whitespace-only note is never a request for changes.
  for blank in ["", " ", "\n\t "] {
    assert_true(ticket_request_changes_blocked(model, blank))
    assert_eq(
      ticket_request_changes_hint(model, blank),
      Some("Write the feedback the next run must address."),
    )
  }
  // The gate re-checks at submit: a blank draft sends nothing at all.
  let blank = feedback_typed(model, "   ")
  let (blocked, command) = update(
    blank,
    RequestChangesSubmitted,
    test_emit,
    test_env(),
  )
  assert_true(blocked == blank)
  debug_inspect(command, content="[]")
}

///|
test "cancelling the request changes editor sends nothing and clears the draft" {
  let model = feedback_model(Json::null())
  let typed = feedback_typed(model, "Add a regression test.")
  let (cancelled, command) = update(
    typed,
    RequestChangesCancelled,
    test_emit,
    test_env(),
  )
  assert_true(cancelled.request_changes_draft is None)
  assert_true(cancelled.replica == model.replica)
  assert_false(cancelled.ticket_sending)
  assert_true(cancelled.notice is None)
  debug_inspect(command, content="[]")
  // The editor only opens on a Review ticket and never over another draft.
  let (wrong_stage, cmd) = update(
    model,
    RequestChangesOpened("b"),
    test_emit,
    test_env(),
  )
  assert_true(wrong_stage == model)
  debug_inspect(cmd, content="[]")
  let (twice, cmd) = update(
    typed,
    RequestChangesOpened("t"),
    test_emit,
    test_env(),
  )
  assert_true(twice == typed)
  debug_inspect(cmd, content="[]")
}

///|
test "Approve stays the one one-click review decision" {
  let model = feedback_model(Json::null())
  assert_eq(review_decision_controls().map(review_decision_label), ["Approve"])
  assert_eq(review_decision_controls().map(decision => decision.to_wire()), [
    "approved",
  ])
  // One click still fills the draft and opens the confirmation.
  let (approved, _) = update(
    model,
    ReviewDecide("a", "approved"),
    test_emit,
    test_env(),
  )
  assert_true(
    approved.review_draft
    is Some({ task_id: "t", attempt_id: "a", decision: Some(Approved), }),
  )
  assert_true(approved.confirm is Some(ConfirmReview))
  assert_true(approved.request_changes_draft is None)
  // Request changes is no longer a recordable decision: the same click is
  // inert, and even a stale Changes-requested draft never reaches the wire.
  let (inert, command) = update(
    model,
    ReviewDecide("a", "changes_requested"),
    test_emit,
    test_env(),
  )
  assert_true(inert == model)
  debug_inspect(command, content="[]")
  let stale = {
    ..approved,
    confirm: None,
    review_draft: Some({
      task_id: "t",
      attempt_id: "a",
      decision: Some(ChangesRequested),
    }),
  }
  let (refused, command) = update(
    stale,
    ConfirmAccepted,
    test_emit,
    counting_env(),
  )
  assert_true(refused.pending is None)
  assert_true(refused.review_draft == stale.review_draft)
  assert_true(refused.confirm is None)
  debug_inspect(command, content="[]")
}

///|
test "review feedback renders in the Review section for the next run" {
  let with_feedback = feedback_model(
    Json::string("Add a regression test for the retry path."),
  )
  let without_feedback = feedback_model(Json::null())
  let task = inspector_task(with_feedback).unwrap()
  assert_eq(
    task.review_feedback,
    Some("Add a regression test for the retry path."),
  )
  assert_eq(inspector_task(without_feedback).unwrap().review_feedback, None)
  // It is labelled as reviewer feedback the next run must address, never as a
  // free-floating note.
  assert_eq(review_feedback_label(), "Reviewer feedback")
  assert_eq(review_feedback_note(), "The next run must address this feedback.")
  assert_true(review_feedback_block("Anything") != @html.nothing)
  let emit : @rabbita.Emit[Msg] = _msg => @rabbita.none
  assert_true(review_block(with_feedback, task, emit) != @html.nothing)
  // The note is what this review is against, so it changes the section itself.
  let bare_task = inspector_task(without_feedback).unwrap()
  assert_true(
    review_block(with_feedback, task, emit) !=
    review_block(without_feedback, bare_task, emit),
  )
  // The editor replaces the one-click Request changes button while it is open.
  let typed = feedback_typed(without_feedback, "Add a regression test.")
  assert_true(request_changes_open(typed, "t"))
  assert_false(request_changes_open(typed, "b"))
  assert_true(
    review_block(typed, bare_task, emit) !=
    review_block(without_feedback, bare_task, emit),
  )
}
