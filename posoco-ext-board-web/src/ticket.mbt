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
  // Runtime catalog: absent, null and unknown shapes all decode to "no
  // catalog in this frame" and never fail the snapshot that carries them.
  let model_selection = match fields.get("model_selection") {
    Some(value) => decode_model_catalog(value)
    None => None
  }
  { questions, runs, model_selection }
}

///|
/// Decode the optional `model_selection` projection. `selectable` defaults to
/// false: a malformed or partial catalog can only ever make the picker
/// read-only, never make a model look selectable.
fn decode_model_catalog(value : Json) -> ModelCatalog? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let selectable = match fields.get("selectable") {
    Some(True) => true
    _ => false
  }
  let kind = match fields.get("kind") {
    Some(String(value)) => value
    _ => ""
  }
  let models = match fields.get("models") {
    Some(Array(items)) => items.filter_map(decode_model_option)
    _ => []
  }
  Some({ selectable, kind, models })
}

///|
/// One catalog entry. Only the stable slot id is required; labels, efforts
/// and capability hints are optional so a partial host projection still
/// renders instead of disappearing.
fn decode_model_option(value : Json) -> ModelOption? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let id = match fields.get("id") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let text = name => {
    match fields.get(name) {
      Some(String(value)) => value
      _ => ""
    }
  }
  let strings = name => {
    match fields.get(name) {
      Some(Array(items)) =>
        items.filter_map(item => {
          match item {
            String(value) if value != "" => Some(value)
            _ => None
          }
        })
      _ => []
    }
  }
  let default_effort = match fields.get("default_effort") {
    Some(String(value)) if value != "" => Some(value)
    _ => None
  }
  let context_window = match fields.get("context_window") {
    Some(Number(value, ..)) => Some(value.to_int64())
    _ => None
  }
  Some({
    id,
    label: text("label"),
    provider: text("provider"),
    model: text("model"),
    efforts: strings("efforts"),
    default_effort,
    context_window,
    capabilities: strings("capabilities"),
  })
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
fn decode_ticket_activity(value : Json) -> TicketActivity? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let text = match fields.get("text") {
    Some(String(value)) => value
    _ => return None
  }
  let kind = match fields.get("kind") {
    Some(String(value)) => value
    _ => "step"
  }
  let at_ms = match fields.get("at_ms") {
    Some(Number(value, ..)) => value.to_int64()
    _ => 0L
  }
  Some({ at_ms, kind, text, })
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
  let steps = match fields.get("steps") {
    Some(Number(value, ..)) => value.to_int()
    _ => 0
  }
  let current_tool = match fields.get("current_tool") {
    Some(String(value)) => Some(value)
    _ => None
  }
  let preview = match fields.get("preview") {
    Some(String(value)) => value
    _ => ""
  }
  let reasoning = match fields.get("reasoning") {
    Some(String(value)) => value
    _ => ""
  }
  let activities = match fields.get("activities") {
    Some(Array(items)) => items.filter_map(decode_ticket_activity)
    _ => []
  }
  Some({
    task_id,
    session_id,
    phase,
    status,
    error,
    result,
    steps,
    current_tool,
    preview,
    reasoning,
    activities,
  })
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
  model.tickets.runs.any(run => {
    run.task_id == task_id && run.status == "running"
  })
}

///|
fn ticket_question_count(model : Model) -> Int32 {
  model.tickets.questions.length()
}

///|
fn ticket_inbox_count(model : Model) -> Int32 {
  ticket_question_count(model)
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
/// Wire arguments for one ticket model change. Kept separate from the send so
/// tests can pin the exact payload: the stable slot id (not the model id) and
/// an explicit `null` model when the ticket returns to inherit.
fn ticket_set_model_args(task_id : String, model : ModelChoice?) -> Json {
  let payload : Json = match model {
    Some(choice) => {
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
fn ticket_dismiss(task_id : String, emit : @rabbita.Emit[Msg]) -> @rabbita.Cmd {
  let args : Json = { "task_id": Json::string(task_id) }
  send_ticket_command("board.ticket.dismiss", args, emit)
}

///|
fn ticket_activity_list(activities : Array[TicketActivity]) -> @html.Html {
  let items : Array[@html.Html] = []
  let start = if activities.length() > 20 { activities.length() - 20 } else { 0 }
  for index in start..<activities.length() {
    let activity = activities[index]
    items.push(
      @html.div(
        class="ticket-activity-row kind-\{activity.kind}",
        @html.span(class="ticket-activity-text", activity.text),
      ),
    )
  }
  @html.div(class="ticket-activity-list", items)
}

///|
fn ticket_run_card(
  model : Model,
  run : TicketRun,
) -> @html.Html {
  let title = match task_by_id(model.replica, run.task_id) {
    Some(task) => task.title
    None => run.task_id
  }
  let phase = if run.phase == "shape" { "Shaping" } else { "Working" }
  let tool = match run.current_tool {
    Some(name) => " · " + name
    None => ""
  }
  let preview = if run.preview == "" {
    "Waiting for the first model response…"
  } else {
    run.preview
  }
  @html.div(class="ticket-question ticket-run", [
    @html.div(class="ticket-question-meta", [
      @html.span(class="ticket-question-task", title),
      @html.span(class="ticket-question-kind", phase + tool),
    ]),
    @html.div(class="ticket-run-preview", preview),
    if run.reasoning == "" {
      @html.nothing
    } else {
      @html.details(class="ticket-reasoning", [
        @html.summary("Reasoning"),
        @html.div(class="ticket-reasoning-text", run.reasoning),
      ])
    },
    ticket_activity_list(run.activities),
    @html.div(
      class="ticket-run-foot",
      "Step \{run.steps} · updates automatically while the worker runs.",
    ),
  ])
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
      class=if run.error is Some(_) {
        "ticket-result-text ticket-result-error"
      } else {
        "ticket-result-text"
      },
      match run.result {
        Some(text) => text
        None =>
          match run.error {
            Some(text) => text
            None => "No result recorded."
          }
      },
    ),
    if run.activities.is_empty() {
      @html.nothing
    } else {
      ticket_activity_list(run.activities)
    },
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
  // The catalog is runtime projection, not ticket journal state: a frame that
  // omitted it (for example a `ticket_result`) keeps the last known catalog
  // instead of disabling a picker the user is looking at.
  let model_selection = match state.model_selection {
    Some(_) => state.model_selection
    None => model.tickets.model_selection
  }
  {
    ..model,
    tickets: { ..state, model_selection },
    ticket_available: true,
    ticket_sending: false,
  }
}

///|
fn ticket_rejection_text(reason : String?) -> String {
  match reason {
    Some("ticket is already running") =>
      "This ticket is already running. Open its Activity dialog to inspect progress."
    Some("ticket must be Backlog, Shaping, or Ready before it can be shaped") =>
      "Move the ticket back to Backlog or Shaping before shaping it again."
    Some("ticket must be Ready before it can run") =>
      "Shape the ticket and move it to Ready before starting work."
    Some("ticket_runtime_unavailable") =>
      "The Board ticket runtime is unavailable. Restart Cetas with workflows enabled."
    Some("ticket_start_failed") | Some("ticket_shape_failed") =>
      "The ticket could not start. Open its Activity dialog for the failure detail."
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
      notice: Some(
        notice(
          Warning,
          if already_running {
            "This ticket is already running. Open its Activity dialog to inspect progress."
          } else {
            ticket_rejection_text(reason)
          },
        ),
      ),
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
      @html.div([
        @html.div(class="ticket-answers", buttons),
        @html.div(class="ticket-other", [
          @html.div(class="ticket-other-label", "Other answer"),
          @html.div(class="ticket-answers", [
            @html.textarea(
              id="ticket-other-\{question.id}",
              name="ticket_other",
              class="ticket-input",
              rows=3,
              value=draft,
              placeholder="None of these fit? Write your answer…",
              disabled=model.ticket_sending,
              on_input=value => emit(TicketDraftChanged(question.id, value)),
              @html.fragment([]),
            ),
            @html.button(
              type_="button",
              class="btn btn-sm btn-primary",
              disabled=model.ticket_sending || draft.trim().is_empty(),
              on_click=emit(TicketAnswered(question.id, TicketText(draft))),
              "Send other",
            ),
          ]),
        ]),
      ])
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
/// Per-ticket Activity dialog: live and finished runs belong to the ticket,
/// not to the question inbox.
fn ticket_activity_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let task_id = match model.ticket_activity_task {
    Some(task_id) => task_id
    None => return @html.nothing
  }
  let task = task_by_id(model.replica, task_id)
  let title = match task {
    Some(task) => task.title
    None => task_id
  }
  let runs = model.tickets.runs.filter(run => run.task_id == task_id)
  let run_label = if runs.length() == 1 {
    "1 run"
  } else {
    "\{runs.length()} runs"
  }
  @html.dialog(
    id="ticket-activity-dialog",
    class="dialog sheet-dialog",
    on_close=_ => emit(TicketActivityClosed),
    attrs=@html.Attrs::build().aria_label("Ticket activity"),
    [
      @html.div(class="sheet", [
        @html.header(class="sheet-head", [
          @html.div(class="sheet-heading", [
            @html.nav(
              class="crumbs",
              attrs=@html.Attrs::build().aria_label("Breadcrumb"),
              [
                @html.button(
                  type_="button",
                  class="crumb-link",
                  attrs=@html.Attrs::build().on_click(_ => {
                    ui_close("ticket-activity-dialog")
                    @rabbita.none
                  }),
                  "Board",
                ),
                @html.span(class="crumb-sep", "/"),
                @html.span(class="crumb-here", title),
                @html.span(class="crumb-sep", "/"),
                @html.span(class="crumb-here", "Activity"),
              ],
            ),
            @html.h2(class="sheet-title", "Activity"),
            @html.p(class="sheet-meta", [
              @html.span(
                class="chip",
                if runs.is_empty() {
                  "No runs yet"
                } else {
                  run_label
                },
              ),
              @html.span(class="chip is-quiet", task_id),
            ]),
          ]),
          close_button("ticket-activity-dialog"),
        ]),
        @html.div(
          class="sheet-body ticket-activity-body",
          if runs.is_empty() {
            [
              @html.div(
                class="empty-line",
                "No agent activity yet. Shape or run this ticket to start.",
              ),
            ]
          } else {
            runs.map(run => {
              if run.status == "running" {
                ticket_run_card(model, run)
              } else {
                ticket_result_card(model, run, emit)
              }
            })
          },
        ),
      ]),
    ],
  )
}

///|
/// The inbox is for questions only. Live and finished run detail lives on the
/// ticket's own Activity dialog.
fn inbox_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let question_count = model.tickets.questions.length()
  @html.dialog(
    id="inbox-dialog",
    class="dialog sheet-dialog",
    on_close=_ => emit(TicketDrawerClosed),
    attrs=@html.Attrs::build().aria_label("Ticket inbox"),
    [
      @html.div(class="sheet", [
        @html.header(class="sheet-head", [
          @html.div(class="sheet-heading", [
            @html.nav(
              class="crumbs",
              attrs=@html.Attrs::build().aria_label("Breadcrumb"),
              [
                @html.button(
                  type_="button",
                  class="crumb-link",
                  attrs=@html.Attrs::build().on_click(_ => {
                    ui_close("inbox-dialog")
                    @rabbita.none
                  }),
                  "Board",
                ),
                @html.span(class="crumb-sep", "/"),
                @html.span(class="crumb-here", "Inbox"),
              ],
            ),
            @html.h2(class="sheet-title", "Inbox"),
            @html.p(
              class="sheet-meta",
              if question_count == 0 {
                @html.span(class="chip is-quiet", "No open questions")
              } else {
                @html.span(
                  class="chip is-accent",
                  "\{question_count} awaiting an answer",
                )
              },
            ),
          ]),
          close_button("inbox-dialog"),
        ]),
        @html.div(
          class="sheet-body inbox-body",
          {
            let items : Array[@html.Html] = []
            for question in model.tickets.questions {
              items.push(ticket_question_card(model, question, emit))
            }
            if items.is_empty() {
              items.push(
                @html.div(
                  class="empty-line",
                  "No open questions.",
                ),
              )
            }
            items
          },
        ),
      ]),
    ],
  )
}
