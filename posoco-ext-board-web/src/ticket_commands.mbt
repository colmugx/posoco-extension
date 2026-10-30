///|
/// Wire frame for one ticket command. Kept separate from the socket send so
/// tests can pin the exact command name and arguments.
fn ticket_command_frame(name : String, args : Json) -> String {
  let frame : Json = {
    "type": "ticket_command",
    "name": Json::string(name),
    "args": args,
  }
  frame.stringify()
}

///|
fn send_ticket_command(
  name : String,
  args : Json,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  @websocket.send("board", Text(ticket_command_frame(name, args)), failed=_ => {
    emit(
      TicketResult(false, Some("The ticket command could not be sent."), None),
    )
  })
}

///|
fn team_mcp_json(mcp : Map[String, TeamMcp]) -> Json {
  let fields : Map[String, Json] = Map([])
  for role in ["po", "sm", "rd", "set", "te"] {
    let value = match mcp.get(role) {
      Some(value) => value
      None => TeamMcp::defaults()
    }
    fields[role] = Json::object({
      "enabled": Json::boolean(value.enabled),
      "all": Json::boolean(value.all),
      "servers": Json::array(value.servers.map(Json::string)),
      "tools": Json::array(value.tools.map(Json::string)),
    })
  }
  Json::object(fields)
}

///|
fn team_skills_json(skills : Map[String, TeamSkills]) -> Json {
  let fields : Map[String, Json] = Map([])
  for role in ["po", "sm", "rd", "set", "te"] {
    let value = match skills.get(role) {
      Some(value) => value
      None => TeamSkills::defaults()
    }
    fields[role] = Json::object({
      "enabled": Json::boolean(value.enabled),
      "all": Json::boolean(value.all),
      "skills": Json::array(value.skills.map(Json::string)),
    })
  }
  Json::object(fields)
}

///|
fn ticket_set_required_roles(
  task_id : String,
  roles : Array[String],
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.set_required_roles",
    {
      "id": Json::string(task_id),
      "roles": Json::array(roles.map(Json::string)),
    },
    emit,
  )
}

///|
fn ticket_set_team(
  names : TeamNames,
  profile : WorkProfile,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  let args : Json = {
    "po": Json::string(names.po.trim().to_owned()),
    "sm": Json::string(names.sm.trim().to_owned()),
    "rd": Json::string(names.rd.trim().to_owned()),
    "set": Json::string(names.set.trim().to_owned()),
    "te": Json::string(names.te.trim().to_owned()),
    "mcp": team_mcp_json(names.mcp),
    "skills": team_skills_json(names.skills),
    "work_profile": Json::string(profile.id),
  }
  send_ticket_command("board.ticket.set_team", args, emit)
}

///|
fn ticket_forward_to_po(
  question_id : String,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.forward_to_po",
    { "question_id": Json::string(question_id) },
    emit,
  )
}

///|
fn ticket_answer(
  question_id : String,
  answer : TicketAnswer,
  emit : @rabbita.Emit[Msg],
  answered_by~ : String = "customer",
) -> @rabbita.Cmd {
  let args : Json = match answer {
    TicketText(value) =>
      {
        "question_id": Json::string(question_id),
        "text": Json::string(value),
        "answered_by": Json::string(answered_by),
      }
    TicketConfirm(value) =>
      {
        "question_id": Json::string(question_id),
        "confirm": Json::boolean(value),
        "answered_by": Json::string(answered_by),
      }
    TicketSelect(value) =>
      {
        "question_id": Json::string(question_id),
        "index": Json::number(value.to_double()),
        "answered_by": Json::string(answered_by),
      }
  }
  send_ticket_command("board.ticket.answer", args, emit)
}

///|
fn ticket_run_ready(emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  send_ticket_command("board.ticket.run_ready", Json::object(Map([])), emit)
}

///|
fn ticket_shape(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  let args : Json = { "task_id": Json::string(task_id) }
  send_ticket_command("board.ticket.shape", args, emit)
}

///|
fn ticket_run(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  let args : Json = { "task_id": Json::string(task_id) }
  send_ticket_command("board.ticket.run", args, emit)
}

///|
/// Wire arguments for one retry. The host resolves them to a brand-new run for
/// the ticket; nothing about the previous child session travels on the wire.
fn ticket_retry_args(task_id : String) -> Json {
  { "task_id": Json::string(task_id) }
}

///|
fn ticket_retry(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  send_ticket_command("board.ticket.retry", ticket_retry_args(task_id), emit)
}

///|
/// Wire arguments for one resume. The host continues the durable child session
/// the interrupted run already owns, so only the ticket identity travels: the
/// session itself stays authoritative on the host.
fn ticket_resume_args(task_id : String) -> Json {
  { "task_id": Json::string(task_id) }
}

///|
fn ticket_resume(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  send_ticket_command("board.ticket.resume", ticket_resume_args(task_id), emit)
}

///|
/// Wire arguments for one Request changes round: which ticket is going back and
/// the reviewer note the next run must address. The note is the reason the
/// command exists, so it is trimmed and never empty when it leaves here.
fn ticket_request_changes_args(task_id : String, feedback : String) -> Json {
  {
    "task_id": Json::string(task_id),
    "feedback": Json::string(feedback.trim().to_owned()),
  }
}

///|
/// Request changes is a ticket command, not an attempt decision: the host
/// records ChangesRequested, moves the task Review → Ready and starts a fresh
/// work run from the feedback.
fn ticket_request_changes(
  task_id : String,
  feedback : String,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.request_changes",
    ticket_request_changes_args(task_id, feedback),
    emit,
  )
}

///|
/// Why Request changes cannot be sent right now, in the same order the gate
/// checks it. The host rejects a blank note, so the editor states every reason
/// instead of leaving the submit button silently disabled.
fn ticket_request_changes_hint(model : Model, feedback : String) -> String? {
  if model.ticket_sending {
    Some("Wait for the current ticket command to finish.")
  } else if !model.can_connect {
    Some("Reconnect to the board before sending feedback.")
  } else if !model.ticket_available {
    Some(ticket_rejection_text(Some("board_work_unavailable")))
  } else if feedback.trim().is_empty() {
    Some("Write the feedback the next run must address.")
  } else {
    None
  }
}

///|
fn ticket_request_changes_blocked(model : Model, feedback : String) -> Bool {
  ticket_request_changes_hint(model, feedback) is Some(_)
}

///|
/// Finished run statuses that left no live worker behind. Only these offer
/// Retry work: a succeeded run is a result to review, not a lost session, and
/// a running one is still owned by its worker.
fn ticket_run_retryable(status : String) -> Bool {
  match status {
    "failed" | "interrupted" | "sync_failed" => true
    _ => false
  }
}

///|
/// A finished run keeps its durable session in these states. A network or work
/// failure is recoverable: Resume run continues the recorded session, while
/// Retry remains the fresh-attempt escape hatch. A blank session id means there
/// is nothing to continue.
fn ticket_run_resumable(run : TicketRun) -> Bool {
  ticket_run_retryable(run.status) && run.session_id != ""
}

///|
/// Every ticket command waits for the in-flight one to clear, needs a socket
/// that can carry it and an advertised runtime, and never fires while this
/// ticket already has a live run.
fn ticket_command_blocked(model : Model, task_id : String) -> Bool {
  model.ticket_sending ||
  !model.can_connect ||
  !model.ticket_available ||
  ticket_task_running(model, task_id)
}

///|
/// Retry work shares the ticket-command gate with every other ticket command.
fn ticket_retry_blocked(model : Model, task_id : String) -> Bool {
  ticket_command_blocked(model, task_id)
}

///|
/// Resume run is gated exactly like Retry: the two offers sit in the same block
/// and must never race each other.
fn ticket_resume_blocked(model : Model, task_id : String) -> Bool {
  ticket_command_blocked(model, task_id)
}

///|
fn ticket_retry_note() -> String {
  "Retry starts a new run from the current ticket. It does not resume the lost session, so the previous worker's context is gone."
}

///|
/// Retry work plus the note that states its consequence. The ticket stays in
/// place: unlike Resume, this action starts a run instead of moving a stage.
fn ticket_retry_action(
  model : Model,
  task_id : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @html.div(class="ticket-retry", [
    @html.div(class="ticket-answers", [
      @html.button(
        type_="button",
        class="btn btn-sm btn-primary",
        title="Start a fresh run for this ticket",
        disabled=ticket_retry_blocked(model, task_id),
        on_click=emit(TicketRetry(task_id)),
        "Retry work",
      ),
    ]),
    @html.p(class="ticket-retry-note", ticket_retry_note()),
  ])
}

///|
/// Wire arguments for one ticket model change. Kept separate from the send so
/// tests can pin the exact payload: the stable slot id (not the model id) and
/// an explicit `null` model when the ticket returns to inherit.
fn ticket_set_model_args(task_id : String, model : ModelChoice?) -> Json {
  let payload : Json = match model {
    Some(choice) =>
      {
        "slot": Json::string(choice.slot),
        "effort": match choice.effort {
          Some(effort) => Json::string(effort)
          None => Json::null()
        },
      }
    None => Json::null()
  }
  { "task_id": Json::string(task_id), "model": payload }
}

///|
fn ticket_set_model(
  task_id : String,
  model : ModelChoice?,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.set_model",
    ticket_set_model_args(task_id, model),
    emit,
  )
}

///|
fn ticket_consult_sm(
  task_id : String,
  question : String,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.consult_sm",
    { "task_id": Json::string(task_id), "question": Json::string(question) },
    emit,
  )
}

///|
fn ticket_dismiss(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  let args : Json = { "task_id": Json::string(task_id) }
  send_ticket_command("board.ticket.dismiss", args, emit)
}

///|
fn ticket_dismiss_updates(emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  send_ticket_command(
    "board.ticket.dismiss_progress",
    Json::object(Map([])),
    emit,
  )
}

