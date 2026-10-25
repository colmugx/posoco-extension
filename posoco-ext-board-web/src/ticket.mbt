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
  // Worker progress: absent reads as empty and every malformed entry is
  // dropped on its own, so one bad update never hides the rest of the inbox.
  let progress = match fields.get("progress") {
    Some(Array(items)) => items.filter_map(decode_ticket_progress)
    _ => []
  }
  // Runtime catalog: absent, null and unknown shapes all decode to "no
  // catalog in this frame" and never fail the snapshot that carries them.
  let model_selection = match fields.get("model_selection") {
    Some(value) => decode_model_catalog(value)
    None => None
  }
  { questions, runs, progress, model_selection }
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
/// One worker progress update. `task_id` and a non-blank `message` are the only
/// required fields: without them there is nothing to show, so the entry is
/// dropped instead of failing the snapshot that carries it. An unknown `kind`
/// falls back to `normal`, and a missing or non-numeric `at_ms` reads as the
/// epoch, matching the question decode.
fn decode_ticket_progress(value : Json) -> TicketProgress? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let task_id = match fields.get("task_id") {
    Some(String(value)) if value != "" => value
    _ => return None
  }
  let message = match fields.get("message") {
    Some(String(value)) if value.trim() != "" => value
    _ => return None
  }
  let kind = match fields.get("kind") {
    Some(String(value)) => ticket_progress_kind(value)
    _ => "normal"
  }
  let at_ms = match fields.get("at_ms") {
    Some(Number(value, ..)) => value.to_int64()
    _ => 0L
  }
  Some({ task_id, kind, message, at_ms, })
}

///|
/// Bounded tone set of the host contract. An unrecognised kind is still a
/// perfectly good update, so it renders with the neutral tone instead of being
/// dropped or given a colour the stylesheet does not define.
fn ticket_progress_kind(kind : String) -> String {
  match kind {
    "milestone" | "attention" | "blocked" => kind
    _ => "normal"
  }
}

///|
/// Human label of one update tone. The word carries the meaning, so colour is
/// never the only signal.
fn ticket_progress_kind_label(kind : String) -> String {
  match kind {
    "milestone" => "Milestone"
    "attention" => "Attention"
    "blocked" => "Blocked"
    _ => "Update"
  }
}

///|
/// Identity of one update for seen tracking. The host may rewrite its bounded
/// progress list between snapshots, so updates are matched by content rather
/// than by index: the same update delivered twice is still one update.
fn ticket_progress_key(update : TicketProgress) -> String {
  "\{update.task_id}|\{update.at_ms}|\{update.kind}|\{update.message}"
}

///|
/// The progress list newest first. The replica's own array is detached, so
/// ordering never leaks into a previous model.
fn ticket_progress_latest_first(
  updates : Array[TicketProgress],
) -> Array[TicketProgress] {
  let ordered = updates.copy()
  ordered.sort_by((left, right) => right.at_ms.compare(left.at_ms))
  ordered
}

///|
/// Seen set for a set of updates. It is rebuilt from the current list instead
/// of accumulated, so identities the host dropped never linger.
fn ticket_progress_seen(updates : Array[TicketProgress]) -> Map[String, Bool] {
  let seen : Map[String, Bool] = Map([])
  for update in updates {
    seen[ticket_progress_key(update)] = true
  }
  seen
}

///|
/// Keep only the seen identities that are still in the authoritative list. A
/// torn-down worker's updates leave the inbox and their keys leave the model.
fn ticket_progress_retain_seen(
  seen : Map[String, Bool],
  updates : Array[TicketProgress],
) -> Map[String, Bool] {
  let kept : Map[String, Bool] = Map([])
  for update in updates {
    let key = ticket_progress_key(update)
    if seen.contains(key) {
      kept[key] = true
    }
  }
  kept
}

///|
/// Short "how long ago" label for one update. The observation time is passed
/// in so the inbox stays a pure projection and tests can pin it; anything older
/// than a month falls back to UTC civil time instead of an implausible count.
fn ticket_progress_age(at_ms : Int64, now_ms : Int64) -> String {
  let age = now_ms - at_ms
  if age < 3600000L {
    if age < 60000L {
      "just now"
    } else {
      "\{age / 60000L}m ago"
    }
  } else if age < 86400000L {
    "\{age / 3600000L}h ago"
  } else if age < 2592000000L {
    "\{age / 86400000L}d ago"
  } else {
    utc_timestamp(at_ms)
  }
}

///|
/// One inbox update row with everything the renderer needs already resolved.
/// Keeping this projection pure lets tests pin the rendered text and tone
/// without a DOM.
priv struct InboxUpdate {
  task_id : String
  /// Ticket title, or the id when the replica cannot resolve the task.
  title : String
  kind : String
  kind_label : String
  message : String
  at_ms : Int64
  time_label : String
  unseen : Bool
}

///|
/// The update rows the inbox renders, newest first.
fn inbox_updates(model : Model, now_ms : Int64) -> Array[InboxUpdate] {
  ticket_progress_latest_first(model.tickets.progress).map(update => {
    let seen = model.ticket_seen_updates.contains(ticket_progress_key(update))
    {
      task_id: update.task_id,
      title: match task_by_id(model.replica, update.task_id) {
        Some(task) => task.title
        None => update.task_id
      },
      kind: update.kind,
      kind_label: ticket_progress_kind_label(update.kind),
      message: update.message,
      at_ms: update.at_ms,
      time_label: ticket_progress_age(update.at_ms, now_ms),
      unseen: !seen,
    }
  })
}

///|
/// The most recent update of one ticket, if its worker reported any. The
/// Activity dialog shows it above the live run so progress is visible where
/// the run is inspected.
fn ticket_latest_update(model : Model, task_id : String) -> TicketProgress? {
  ticket_progress_latest_first(model.tickets.progress)
    .filter(update => update.task_id == task_id)
    .get(0)
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
/// Worker updates the user has not looked at yet. Opening the inbox records the
/// list that was on screen as seen; anything a worker reports afterwards is
/// unseen again until the next open.
fn ticket_unseen_update_count(model : Model) -> Int32 {
  model.tickets.progress.filter(update => {
    !model.ticket_seen_updates.contains(ticket_progress_key(update))
  }).length()
}

///|
/// The inbox badge counts both things waiting for a human: open questions that
/// need an answer, and worker updates that arrived since the inbox was opened.
fn ticket_inbox_count(model : Model) -> Int32 {
  ticket_question_count(model) + ticket_unseen_update_count(model)
}

///|
/// Header and section wording for the unseen updates. Plain words, never a raw
/// count with no noun.
fn ticket_update_count_label(count : Int32) -> String {
  if count == 1 {
    "1 new update"
  } else {
    "\{count} new updates"
  }
}

///|
/// Total update count for the header chip, separate from the unseen count so
/// the inbox still reports how much the workers said when nothing is new.
fn ticket_update_total_label(count : Int32) -> String {
  if count == 1 {
    "1 update"
  } else {
    "\{count} updates"
  }
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
    Some(ticket_rejection_text(Some("ticket_runtime_unavailable")))
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
/// A run only survives a host restart as `interrupted`, and only then keeps the
/// durable session Resume run continues. A failed or sync-failed run has nothing
/// left to continue, so it can only be retried.
fn ticket_run_resumable(run : TicketRun) -> Bool {
  run.status == "interrupted" && run.session_id != ""
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
/// The action one finished run offers under its card. Resume run continues the
/// durable session the interrupted run already owns; Retry starts a new run and
/// clears it.
priv enum TicketRunAction {
  ResumeRun
  RetryRun
}

///|
/// The actions one finished run offers, primary first. An interrupted run that
/// still holds a session prefers continuing it, so Resume run comes first and
/// Retry follows as the escape hatch; a failed or sync-failed run has no
/// session left and only offers Retry, while a running run is still owned by
/// its worker.
fn ticket_run_actions(run : TicketRun) -> Array[TicketRunAction] {
  let actions : Array[TicketRunAction] = []
  if ticket_run_resumable(run) {
    actions.push(ResumeRun)
  }
  if ticket_run_retryable(run.status) {
    actions.push(RetryRun)
  }
  actions
}

///|
/// Resume run and Retry mean different things, so the interrupted card states
/// both consequences instead of leaving the user to guess which one keeps
/// context. The label keeps "run" so it never reads as the ticket's own
/// Suspended → Ready Resume move.
fn ticket_resume_note() -> String {
  "Resume run continues the durable session where it stopped. Retry starts a new run and clears it."
}

///|
/// The visible label of one finished-run action. Resume run stays distinct from
/// the card's own Suspended → Ready Resume stage move.
fn ticket_run_action_label(action : TicketRunAction) -> String {
  match action {
    ResumeRun => "Resume run"
    RetryRun => "Retry work"
  }
}

///|
fn ticket_run_action_button(
  model : Model,
  task_id : String,
  action : TicketRunAction,
  primary : Bool,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let button_class = if primary {
    "btn btn-sm btn-primary"
  } else {
    "btn btn-sm"
  }
  match action {
    ResumeRun =>
      @html.button(
        type_="button",
        class=button_class,
        title="Resume run: continue this run's durable session",
        disabled=ticket_resume_blocked(model, task_id),
        on_click=emit(TicketResume(task_id)),
        ticket_run_action_label(action),
      )
    RetryRun =>
      @html.button(
        type_="button",
        class=button_class,
        title="Start a fresh run for this ticket",
        disabled=ticket_retry_blocked(model, task_id),
        on_click=emit(TicketRetry(task_id)),
        ticket_run_action_label(action),
      )
  }
}

///|
/// Resume and Retry for one finished run card, or nothing when that run still
/// holds a live worker or already produced a result worth keeping. The gate only
/// disables the buttons: an interrupted run keeps offering both while the
/// socket reconnects.
fn ticket_run_action_block(
  model : Model,
  run : TicketRun,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let actions = ticket_run_actions(run)
  if actions.is_empty() {
    return @html.nothing
  }
  let buttons : Array[@html.Html] = []
  for index, action in actions {
    buttons.push(
      ticket_run_action_button(model, run.task_id, action, index == 0, emit),
    )
  }
  let resumable = actions.any(action => action is ResumeRun)
  @html.div(class="ticket-run-actions", [
    @html.div(class="ticket-answers", buttons),
    @html.p(
      class="ticket-run-actions-note",
      if resumable {
        ticket_resume_note()
      } else {
        ticket_retry_note()
      },
    ),
  ])
}

///|
/// A paused ticket that never started a run has no card to retry, so the
/// dialog still offers Retry work next to the ticket's own Resume move.
fn ticket_stage_retry_action(
  model : Model,
  task : @client.ClientBoardTask?,
  task_id : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let has_run = model.tickets.runs.any(run => run.task_id == task_id)
  match task {
    Some(task) if task.stage is @client.Suspended && !has_run =>
      ticket_retry_action(model, task_id, emit)
    _ => @html.nothing
  }
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
    // The newest worker update sits above the live preview: it is the same
    // information the inbox shows, repeated where the run is inspected.
    match ticket_latest_update(model, run.task_id) {
      Some(update) =>
        @html.div(class="ticket-update is-compact kind-\{update.kind}", [
          @html.span(
            class="ticket-update-kind",
            ticket_progress_kind_label(update.kind),
          ),
          @html.span(class="ticket-update-text", update.message),
        ])
      None => @html.nothing
    },
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
    ticket_run_action_block(model, run, emit),
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
    // Only the updates still on the wire stay "seen": a worker that tore down
    // takes its updates with it, so its identities must not linger.
    ticket_seen_updates: ticket_progress_retain_seen(
      model.ticket_seen_updates,
      state.progress,
    ),
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
              ticket_stage_retry_action(model, task, task_id, emit),
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
/// One inbox update row. It is information only: no answer control, no stage
/// move and no dismiss, because the worker owns the run and the host owns the
/// list.
fn ticket_update_card(update : InboxUpdate) -> @html.Html {
  let unseen = if update.unseen { " is-unseen" } else { "" }
  @html.article(class="ticket-update kind-\{update.kind}\{unseen}", [
    @html.div(class="ticket-update-meta", [
      @html.span(
        class="ticket-update-task",
        title=update.task_id,
        update.title,
      ),
      @html.span(class="ticket-update-kind", update.kind_label),
      if update.unseen {
        @html.span(class="ticket-update-new", "New")
      } else {
        @html.nothing
      },
      @html.span(
        class="ticket-update-time",
        title=utc_timestamp(update.at_ms),
        update.time_label,
      ),
    ]),
    @html.p(class="ticket-update-text", update.message),
  ])
}

///|
/// The Updates block. It sits above the questions because it is the freshest
/// thing the workers said, and it states in words that no reply is expected so
/// an update never reads as an unanswered question.
fn ticket_updates_section(
  updates : Array[InboxUpdate],
  unseen_count : Int32,
) -> @html.Html {
  @html.section(
    class="inbox-updates",
    attrs=@html.Attrs::build().aria_label("Worker updates"),
    [
      @html.header(class="inbox-section-head", [
        @html.h3(class="inbox-section-title", "Updates"),
        @html.span(
          class="inbox-section-hint",
          if unseen_count == 0 {
            "Information only — no reply needed."
          } else {
            "Information only — \{ticket_update_count_label(unseen_count)} since you last opened the inbox."
          },
        ),
      ]),
      @html.div(
        class="inbox-update-list",
        updates.map(update => ticket_update_card(update)),
      ),
    ],
  )
}

///|
/// The inbox holds two different things: questions that need a human answer,
/// and worker updates that need nothing. Live and finished run detail lives on
/// the ticket's own Activity dialog.
fn inbox_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let question_count = model.tickets.questions.length()
  let update_count = model.tickets.progress.length()
  let unseen_count = ticket_unseen_update_count(model)
  let updates = inbox_updates(model, board_now_ms())
  let items : Array[@html.Html] = []
  if !updates.is_empty() {
    items.push(ticket_updates_section(updates, unseen_count))
  }
  for question in model.tickets.questions {
    items.push(ticket_question_card(model, question, emit))
  }
  if question_count == 0 {
    items.push(@html.div(class="empty-line", "No open questions."))
  }
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
            @html.p(class="sheet-meta", [
              if question_count == 0 {
                @html.span(class="chip is-quiet", "No open questions")
              } else {
                @html.span(
                  class="chip is-accent",
                  "\{question_count} awaiting an answer",
                )
              },
              if update_count == 0 {
                @html.nothing
              } else {
                @html.span(
                  class="chip is-quiet",
                  ticket_update_total_label(update_count),
                )
              },
              if unseen_count == 0 {
                @html.nothing
              } else {
                @html.span(
                  class="chip is-running",
                  ticket_update_count_label(unseen_count),
                )
              },
            ]),
          ]),
          close_button("inbox-dialog"),
        ]),
        @html.div(
          class="sheet-body inbox-body",
          items,
        ),
      ]),
    ],
  )
}
