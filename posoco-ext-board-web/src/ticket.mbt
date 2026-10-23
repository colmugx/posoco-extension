///|
/// Host-side ticket frames. V1 keeps these outside the Board v1 wire contract
/// so the authoritative task/attempt protocol stays unchanged; v2 will
/// replace this shim with first-class ticket/session records.
priv enum TicketFrame {
  TicketSnapshot(TicketState)
  TicketOutcome(Bool, String?, TicketState?)
}

///|
fn ticket_state_from_json(value : Json) -> TicketState {
  let fields = match value {
    Object(fields) => fields
    _ => return TicketState::empty()
  }
  let questions = match fields.get("questions") {
    Some(Array(items)) => items.filter_map(decode_ticket_question)
    _ => []
  }
  let runs = match fields.get("runs") {
    Some(Array(items)) => items.filter_map(decode_ticket_run)
    _ => []
  }
  { questions, runs, }
}

///|
fn decode_ticket_question(value : Json) -> TicketQuestion? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let id = match fields.get("id") {
    Some(String(value)) => value
    _ => return None
  }
  let task_id = match fields.get("task_id") {
    Some(String(value)) => value
    _ => return None
  }
  let question = match fields.get("question") {
    Some(String(value)) => value
    _ => return None
  }
  let kind = match fields.get("kind") {
    Some(String(value)) => value
    _ => return None
  }
  let options = match fields.get("options") {
    Some(Array(items)) =>
      items.filter_map(item => {
        match item {
          String(value) => Some(value)
          _ => None
        }
      })
    _ => []
  }
  let asked_at = match fields.get("asked_at") {
    Some(Number(value, ..)) => value.to_int64()
    _ => 0L
  }
  Some({ id, task_id, question, kind, options, asked_at, })
}

///|
fn decode_ticket_run(value : Json) -> TicketRun? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let task_id = match fields.get("task_id") {
    Some(String(value)) => value
    _ => return None
  }
  let session_id = match fields.get("session_id") {
    Some(String(value)) => value
    _ => ""
  }
  let phase = match fields.get("phase") {
    Some(String(value)) => value
    _ => "work"
  }
  let status = match fields.get("status") {
    Some(String(value)) => value
    _ => "running"
  }
  let error = match fields.get("error") {
    Some(String(value)) => Some(value)
    _ => None
  }
  let result = match fields.get("result") {
    Some(String(value)) => Some(value)
    _ => None
  }
  Some({ task_id, session_id, phase, status, error, result, })
}

///|
fn ticket_frame(text : String) -> TicketFrame? {
  let parsed = @json.parse(text) catch { _ => return None }
  let fields = match parsed {
    Object(fields) => fields
    _ => return None
  }
  match fields.get("type") {
    Some(String("ticket_state")) =>
      match fields.get("state") {
        Some(state) => Some(TicketSnapshot(ticket_state_from_json(state)))
        None => None
      }
    Some(String("ticket_result")) => {
      let ok = match fields.get("ok") {
        Some(True) => true
        _ => false
      }
      let reason = match fields.get("reason") {
        Some(String(value)) => Some(value)
        _ => None
      }
      let state = match fields.get("state") {
        Some(state) => Some(ticket_state_from_json(state))
        None => None
      }
      Some(TicketOutcome(ok, reason, state))
    }
    _ => None
  }
}

///|
fn send_ticket_command(
  name : String,
  args : Json,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  let frame : Json = {
    "type": "ticket_command",
    "name": Json::string(name),
    "args": args,
  }
  @websocket.send("board", Text(frame.stringify()), failed=_ => {
    emit(
      TicketResult(false, Some("The ticket command could not be sent."), None),
    )
  })
}

///|
fn ticket_run_ready(emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  send_ticket_command("board.ticket.run_ready", Json::object(Map([])), emit)
}

///|
fn ticket_answer(
  question_id : String,
  answer : TicketAnswer,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  let args : Json = match answer {
    TicketText(value) =>
      { "question_id": Json::string(question_id), "text": Json::string(value) }
    TicketConfirm(value) =>
      {
        "question_id": Json::string(question_id),
        "confirm": Json::boolean(value),
      }
    TicketSelect(value) =>
      {
        "question_id": Json::string(question_id),
        "index": Json::number(value.to_double()),
      }
  }
  send_ticket_command("board.ticket.answer", args, emit)
}

///|
fn ticket_task_running(model : Model, task_id : String) -> Bool {
  model.tickets.runs.any(run =>
    run.task_id == task_id && run.status == "running"
  )
}

///|
fn ticket_question_count(model : Model) -> Int32 {
  model.tickets.questions.length()
}

///|
fn ticket_inbox_count(model : Model) -> Int32 {
  ticket_question_count(model) +
  model.tickets.runs.filter(run => run.result is Some(_)).length()
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
fn ticket_dismiss(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  let args : Json = { "task_id": Json::string(task_id) }
  send_ticket_command("board.ticket.dismiss", args, emit)
}

///|
fn ticket_result_card(
  model : Model,
  run : TicketRun,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let title = match task_by_id(model.replica, run.task_id) {
    Some(task) => task.title
    None => run.task_id
  }
  @html.div(class="ticket-question ticket-result", [
    @html.div(class="ticket-question-meta", [
      @html.span(class="ticket-question-task", title),
      @html.span(class="ticket-question-kind", run.status),
    ]),
    @html.div(
      class="ticket-result-text",
      match run.result {
        Some(text) => text
        None => "No result recorded."
      },
    ),
    @html.div(class="ticket-answers", [
      @html.button(
        type_="button",
        class="btn btn-sm",
        disabled=model.ticket_sending,
        on_click=emit(TicketResultDismissed(run.task_id)),
        "Dismiss",
      ),
    ]),
  ])
}

///|
fn apply_ticket_state(model : Model, state : TicketState) -> Model {
  { ..model, tickets: state, ticket_available: true, ticket_sending: false, }
}

///|
fn ticket_rejection_text(reason : String?) -> String {
  match reason {
    Some("ticket is already running") =>
      "This ticket is already running. Check Inbox for a question, or wait for it to finish."
    Some("ticket must be Backlog or Shaping before it can be shaped") =>
      "Move the ticket back to Backlog or Shaping before shaping it again."
    Some("ticket must be Ready before it can run") =>
      "Shape the ticket and move it to Ready before starting work."
    Some("ticket_runtime_unavailable") =>
      "The Board ticket runtime is unavailable. Restart Cetas with workflows enabled."
    Some("ticket_start_failed") | Some("ticket_shape_failed") =>
      "The ticket could not start. Open Inbox for the failure detail."
    Some(text) if text != "" => text
    _ => "The ticket command was rejected."
  }
}

///|
fn apply_ticket_outcome(
  model : Model,
  ok : Bool,
  reason : String?,
  state : TicketState?,
) -> Model {
  let next = match state {
    Some(state) => apply_ticket_state(model, state)
    None =>
      ({ ..model, ticket_available: true, ticket_sending: false, } : Model)
  }
  if ok {
    { ..next, last_status: "Ticket updated", }
  } else {
    let already_running = reason == Some("ticket is already running")
    {
      ..next,
      ticket_drawer: next.ticket_drawer || already_running,
      notice: Some(notice(Warning, ticket_rejection_text(reason))),
    }
  }
}

///|
fn ready_ticket_count(model : Model) -> Int32 {
  model.replica.tasks().filter(task => task.stage == @client.Ready).length()
}

///|
fn ticket_question_card(
  model : Model,
  question : TicketQuestion,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let title = match task_by_id(model.replica, question.task_id) {
    Some(task) => task.title
    None => question.task_id
  }
  let draft = model.ticket_drafts.get(question.id).unwrap_or("")
  let answer_controls = match question.kind {
    "confirm" =>
      @html.div(class="ticket-answers", [
        @html.button(
          type_="button",
          class="btn btn-sm",
          disabled=model.ticket_sending,
          on_click=emit(TicketAnswered(question.id, TicketConfirm(true))),
          "Yes",
        ),
        @html.button(
          type_="button",
          class="btn btn-sm",
          disabled=model.ticket_sending,
          on_click=emit(TicketAnswered(question.id, TicketConfirm(false))),
          "No",
        ),
      ])
    "select" => {
      let buttons : Array[@html.Html] = []
      for index in 0..<question.options.length() {
        buttons.push(
          @html.button(
            type_="button",
            class="btn btn-sm",
            disabled=model.ticket_sending,
            on_click=emit(TicketAnswered(question.id, TicketSelect(index))),
            question.options[index],
          ),
        )
      }
      @html.div(class="ticket-answers", buttons)
    }
    _ =>
      @html.div(class="ticket-answers", [
        @html.textarea(
          id="ticket-answer-\{question.id}",
          name="ticket_answer",
          class="ticket-input",
          rows=4,
          value=draft,
          placeholder="Write your answer or feedback…",
          disabled=model.ticket_sending,
          on_input=value => emit(TicketDraftChanged(question.id, value)),
          @html.fragment([]),
        ),
        @html.button(
          type_="button",
          class="btn btn-sm btn-primary",
          disabled=model.ticket_sending || draft.trim().is_empty(),
          on_click=emit(TicketAnswered(question.id, TicketText(draft))),
          "Send",
        ),
      ])
  }
  @html.div(class="ticket-question", [
    @html.div(class="ticket-question-meta", [
      @html.span(class="ticket-question-task", title),
      @html.span(class="ticket-question-kind", question.kind),
    ]),
    @html.div(class="ticket-question-text", question.question),
    answer_controls,
  ])
}

///|
fn ticket_drawer(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  if !model.ticket_drawer {
    return @html.nothing
  }
  @html.div(class="ticket-drawer", [
    @html.div(class="ticket-drawer-head", [
      @html.div([
        @html.div(class="inspector-title", "Ticket inbox"),
        @html.div(
          class="inspector-subtitle",
          "Answer ticket questions here; completed workers show their result below.",
        ),
      ]),
      @html.button(
        type_="button",
        class="btn btn-sm",
        on_click=emit(TicketDrawerToggled),
        "Close",
      ),
    ]),
    @html.div(
      class="ticket-drawer-body",
      {
        let items : Array[@html.Html] = []
        for question in model.tickets.questions {
          items.push(ticket_question_card(model, question, emit))
        }
        for run in model.tickets.runs {
          if run.result is Some(_) {
            items.push(ticket_result_card(model, run, emit))
          }
        }
        if items.is_empty() {
          items.push(
            @html.div(
              class="empty-line",
              "No open questions or completed tickets.",
            ),
          )
        }
        items
      },
    ),
  ])
}
