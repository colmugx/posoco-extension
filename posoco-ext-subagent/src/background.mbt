///|
/// Background bookkeeping for the core task capability: the child registry
/// backing `resume` and the domain projection of delivered background
/// outcomes. The extension owns no delivery machinery — core routes every
/// background terminal into the parent session's inbox, and the result
/// surfaces as a user message in the session's next ordinary turn. The
/// extension's jobs are the declaration-only `background_exited` event at
/// true task exit (hosts/observers learn a death immediately; the runner
/// does no bookkeeping there), observation at the delivery point
/// (`before_model`) plus the `background_delivered` ack (task id, exactly
/// once when the envelope enters model input) and the authoritative
/// `background_terminal` event hosts listen for.

///|
/// Registry entry state for one spawned child: `Running` from spawn until
/// the delivery-point observation records the state word and the final
/// summary text (foreground and background alike — both advertise the id in
/// their footer). `WaitingReply` marks an interactive child parked on a
/// parent answer: not terminal, and the wait must not surface as a
/// completion. The summary is read back by hosts/tests through the
/// registry itself.
#warnings("-unused_field")
priv enum BackgroundRecordState {
  Running
  WaitingReply(String)
  Done(String, String)
}

///|
priv struct BackgroundRecord {
  /// Kind preset the child was spawned with (subscription event payload).
  kind : String
  /// Parent session that spawned this child: a queued question wakes the
  /// spawning session, never whichever session happens to run last.
  session : String
  mut state : BackgroundRecordState
}

///|
fn BackgroundRecord::BackgroundRecord(
  kind~ : String,
  session~ : String = "",
) -> BackgroundRecord {
  { kind, session, state: Running, }
}

///|
/// Host-facing dynamic subscription: appends to the same
/// channel the constructor's `observers` seeded. Manifest stays unchanged.
pub fn SubagentTools::subscribe(
  self : SubagentTools,
  cb : (@kit.SubagentEvent) -> Unit,
) -> Unit {
  self.observers.push(cb)
}

///|
/// Snapshot of every registered child (foreground and background spawns):
/// session id + state word ("running" / "waiting_reply" / "completed" /
/// "failed" / "timed_out" / "cancelled"), in spawn order.
pub fn SubagentTools::background_children(
  self : SubagentTools,
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for id, record in self.registry {
    let word = match record.state {
      Running => "running"
      WaitingReply(_) => "waiting_reply"
      Done(word, _) => word
    }
    out.push((id, word))
  }
  out
}

///|
/// Emit one extension-labeled `Custom` event on the subscription channel.
/// `parent_call` is the spawning call id for events that belong to a live
/// foreground run; lifecycle labels for background children pass
/// `"background"` (no parent row exists).
fn SubagentTools::emit_custom(
  self : SubagentTools,
  child_session : String,
  kind : String,
  parent_call : String,
  label : String,
  data : Json,
) -> Unit {
  let event : @kit.SubagentEvent = {
    child_session,
    kind,
    parent_call,
    event: @posoco.TurnEvent::Custom(
      source="posoco_ext_subagent",
      label~,
      data~,
    ),
  }
  for callback in self.observers {
    callback(event)
  }
}

///|
/// Bound the best-effort exit detail; the authoritative full summary travels
/// with the delivered outcome envelope.
const EXIT_DETAIL_CHARS = 2_000

///|
/// Declaration-only broadcast at true task exit: hosts and observers learn a
/// background child's death immediately instead of at the next delivery scan.
/// The state word is best-effort (`"completed"` / `"failed"` /
/// `"cancelled"` — a core-side timeout surfaces here as `"cancelled"`
/// because the timer lives outside the runner); the authoritative
/// `background_terminal` event with the final classification and summary
/// still fires exactly once at the delivery point. No registry bookkeeping
/// happens here because cancellation mid-run cannot guarantee completion.
fn SubagentTools::emit_exit(
  self : SubagentTools,
  kind~ : String,
  child_session~ : String,
  state_word~ : String,
  detail~ : String,
) -> Unit {
  self.emit_custom(
    child_session,
    kind,
    "background",
    "background_exited",
    Json::object({
      "child_session": Json::string(child_session),
      "kind": Json::string(kind),
      "state": Json::string(state_word),
      "detail": Json::string(@devkit.truncate_chars(detail, EXIT_DETAIL_CHARS)),
    }),
  )
}

///|
/// Wire phase: capture the composed task and wakeup capabilities the
/// manifest requires.
impl @posoco.Lifecycle for SubagentTools with fn on_compose(
  self : SubagentTools,
  view : @posoco.CompositionView,
) {
  self.tasks = view.tasks()
  self.wakeup = view.wakeup()
}

///|
impl @posoco.Lifecycle for SubagentTools with fn on_shutdown(
  self : SubagentTools,
) {
  // Waits end as cancellations, never as hangs; children themselves die
  // with the Agent-owned task scope.
  self.question.reject_all()
}

///|
/// Track the parent session from scoped events: a background task's result
/// is addressed to the session whose turn spawned it. Out-of-run events
/// (scope `None`) go to the wakeup policy — core's ready projection carries
/// no scope, session attribution travels in the event data.
impl @posoco.Observer for SubagentTools with fn on_event(
  self : SubagentTools,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match scope {
    Some(s) => {
      self.session = Some(s.session_id.to_string())
      if event is @posoco.TurnEvent::TurnStarted {
        self.ledger.reset()
      }
    }
    None => self.observe_ready(event)
  }
}

///|
/// Coalescing key for automatic wakeup requests: one stable tag per parent
/// session, so a burst of background completions shares one ticket and a
/// single ordinary turn delivers every outcome already boxed in the inbox.
const BACKGROUND_WAKEUP_TAG = "subagent-background"

///|
/// Fixed explanation carried as the wakeup note. Deliberately constant: the
/// outcome body never travels with the request — it stays in the session
/// inbox, and delivery remains core-owned through the existing injection
/// point.
const BACKGROUND_WAKEUP_NOTE = "a background subagent finished; its outcome envelope is queued in this session's inbox"

///|
/// String value of one field in a `Custom` event's JSON payload; a missing
/// field or non-string value projects to the empty string.
fn json_string_field(data : Json, key : String) -> String {
  match data {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(Json::String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
/// Automatic wakeup policy (docs/wakeup-port.md §10), default off. Core's
/// `background_outcome_ready` fires only after the outcome was boxed into
/// the session inbox and before any wakeup-driven input could read it; when
/// the policy is enabled and the receipt belongs to one of this extension's
/// still-undelivered background tasks, request one ordinary turn for the
/// receipt's own session through the Agent-owned wakeup capability. The
/// request is synchronous admission (never awaits, safe from observers) and
/// stays scheduling-only: no session-store or Puppet access. With the policy
/// off nothing here runs and lazy delivery is preserved; a rejected request
/// (in practice only `ScopeInactive` after shutdown) also falls back to lazy
/// delivery.

///|
/// Coalescing key for question-side wakeup requests: one stable tag per
/// parent session, mirroring the background-outcome tag above.
const QUESTION_WAKEUP_TAG = "subagent-question"

///|
const QUESTION_WAKEUP_NOTE = "a subagent asked you a question; its [subagent-question] envelope is queued for your next turn's model input"

///|
/// Broker hook tail for every question that lands in the injection queue
/// (no live spawning-tool race carries it in-wave — a background child's
/// ask, or a later ask from an already-receipted interactive child).
/// Registry projects to `WaitingReply`; then, under the §10 auto-wakeup
/// policy, one ordinary turn is requested for the session that spawned the
/// child. Synchronous admission only (safe from task bodies, where the
/// asking child runs); a rejected or policy-off request falls back to lazy
/// injection on the parent's next ordinary turn.
fn SubagentTools::handle_question_queued(
  self : SubagentTools,
  info : QuestionInfo,
) -> Unit {
  match self.registry.get(info.child_session) {
    Some(record) =>
      if record.state is Running {
        record.state = WaitingReply(info.id)
      }
    None => ()
  }
  if !self.auto_wakeup {
    return
  }
  let wakeup = match self.wakeup {
    Some(wakeup) => wakeup
    None => return
  }
  let session = match self.registry.get(info.child_session) {
    Some(record) if record.session != "" => record.session
    _ =>
      match self.session {
        Some(session) => session
        None => return
      }
  }
  ignore(
    wakeup.request(session~, tag=QUESTION_WAKEUP_TAG, note=QUESTION_WAKEUP_NOTE),
  )
}

///|
fn SubagentTools::observe_ready(
  self : SubagentTools,
  event : @posoco.TurnEvent,
) -> Unit {
  if !self.auto_wakeup {
    return
  }
  let wakeup = match self.wakeup {
    Some(wakeup) => wakeup
    None => return
  }
  let (source, label, data) = match event {
    @posoco.TurnEvent::Custom(source~, label~, data~) => (source, label, data)
    _ => return
  }
  if source != "posoco.tasks" || label != "background_outcome_ready" {
    return
  }
  let task_id = json_string_field(data, "task_id")
  let session = json_string_field(data, "session")
  // Ownership and freshness: only a receipt this extension accepted whose
  // outcome is still undelivered; the session comes from the event data,
  // never from the display-side tracked session.
  if task_id == "" || session == "" || !self.unobserved.contains(task_id) {
    return
  }
  ignore(
    wakeup.request(
      session~,
      tag=BACKGROUND_WAKEUP_TAG,
      note=BACKGROUND_WAKEUP_NOTE,
    ),
  )
}

///|
/// Delivery-point observation, not injection: core delivers each background
/// terminal as a user message in the session's next ordinary turn; the
/// model input is scanned here first and returned unchanged. Queued
/// subagent questions are the exception — they have no core delivery
/// channel, so they are appended here (each id exactly once).
impl @posoco.PipelineHook for SubagentTools with fn before_model(
  self : SubagentTools,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] raise @posoco.HookAbort {
  self.observe_deliveries(messages)
  self.inject_queued_questions(messages)
}

///|
/// Text projection of one `UiRequest` prompt; every variant carries one.
fn request_prompt(req : @posoco.UiRequest) -> String {
  match req {
    @posoco.UiRequest::Input(prompt~, ..) => prompt
    @posoco.UiRequest::Confirm(prompt~) => prompt
    @posoco.UiRequest::Select(prompt~, ..) => prompt
  }
}

///|
/// One queued question's envelope line: everything the parent model needs
/// to answer without any other lookup.
fn question_envelope(info : QuestionInfo, kind : String) -> String {
  let type_note = match info.req {
    @posoco.UiRequest::Input(..) => "input"
    @posoco.UiRequest::Confirm(..) => "confirm"
    @posoco.UiRequest::Select(options~, ..) =>
      "select options: \{options.join(" | ")}"
  }
  let kind_note = if kind == "" { "" } else { " kind=\{kind}" }
  "[subagent-question id=\{info.id} child=\{info.child_session}\{kind_note}] (\{type_note}): \{request_prompt(info.req)} — answer with answer_question(question_id=\"\{info.id}\")"
}

///|
/// Append one synthetic user message carrying every un-injected question
/// envelope, and announce each on the subscription channel (parent_call is
/// the background label: these asks arrive outside any live subagent-tool
/// call). Exactly-once per question id — the drain is the delivery.
fn SubagentTools::inject_queued_questions(
  self : SubagentTools,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  let queued = self.question.take_queued()
  if queued.is_empty() {
    return messages
  }
  let lines : Array[String] = []
  for info in queued {
    let kind = match self.registry.get(info.child_session) {
      Some(record) => record.kind
      None => ""
    }
    lines.push(question_envelope(info, kind))
    self.emit_custom(
      info.child_session,
      kind,
      "background",
      "question_asked",
      Json::object({
        "question_id": Json::string(info.id),
        "child_session": Json::string(info.child_session),
        "question": Json::string(request_prompt(info.req)),
        "type": Json::string(
          match info.req {
            @posoco.UiRequest::Input(..) => "input"
            @posoco.UiRequest::Confirm(..) => "confirm"
            @posoco.UiRequest::Select(..) => "select"
          },
        ),
      }),
    )
  }
  messages.push(
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text(
        "A subagent asked you a question while you were busy or away:\n\{lines.join("\n")}",
      ),
    ]),
  )
  messages
}

///|
/// Scan the model input for delivered background outcomes (ruling: terminal
/// observation lives at the delivery point). For every still-unobserved
/// receipt id, a matching `[posoco-task-outcome id=<id>]` envelope emits the
/// `background_delivered` ack (task id on the existing subscription channel,
/// exactly once per task id — re-delivery scans are then no-ops), updates
/// the registry record, fires the `background_terminal` subscription event,
/// and leaves the unobserved set.
fn SubagentTools::observe_deliveries(
  self : SubagentTools,
  messages : Array[@posoco.Message],
) -> Unit {
  for message in messages {
    let text = message_text(message)
    // Collect first, mutate after: no map mutation during iteration.
    let matched : Array[String] = []
    for id, _child_session in self.unobserved {
      if text.contains("[posoco-task-outcome id=\{id}]") {
        matched.push(id)
      }
    }
    for id in matched {
      let child_session = match self.unobserved.get(id) {
        Some(session) => session
        None => continue
      }
      self.unobserved.remove(id)
      self.emit_delivered(task_id=id, child_session~)
      match parse_outcome_detail(text) {
        Some((state_word, summary)) =>
          self.record_terminal(child_session, state_word, summary)
        None => ()
      }
    }
  }
}

///|
/// Delivery ack for one consumed outcome envelope: emitted by the first
/// scan that saw the envelope in model input, keyed by task id so hosts can
/// close their ready receipts. Independent of the terminal classification,
/// which keeps its own gating in `record_terminal`.
fn SubagentTools::emit_delivered(
  self : SubagentTools,
  task_id~ : String,
  child_session~ : String,
) -> Unit {
  let kind = match self.registry.get(child_session) {
    Some(record) => record.kind
    None => ""
  }
  self.emit_custom(
    child_session,
    kind,
    "background",
    "background_delivered",
    Json::object({
      "task_id": Json::string(task_id),
      "child_session": Json::string(child_session),
    }),
  )
}

///|
/// Registry update at the delivery point: only a record that exists and is
/// not yet `Done` transitions (idempotent against re-delivery scans), the
/// terminal event fires exactly once per child, and every parked question
/// of the child is closed — a terminal child has no live asks.
fn SubagentTools::record_terminal(
  self : SubagentTools,
  child_session : String,
  state_word : String,
  summary : String,
) -> Unit {
  let record = match self.registry.get(child_session) {
    Some(record) => record
    None => return
  }
  match record.state {
    Done(_) => return
    Running | WaitingReply(_) => ()
  }
  self.question.drop_child(child_session)
  record.state = Done(state_word, summary)
  self.emit_custom(
    child_session,
    record.kind,
    "background",
    "background_terminal",
    Json::object({
      "child_session": Json::string(child_session),
      "kind": Json::string(record.kind),
      "state": Json::string(state_word),
      "summary": Json::string(summary),
    }),
  )
}

///|
/// Text projection of a user message: concatenated `Text` blocks, other
/// block kinds ignored, non-user messages project to the empty string.
fn message_text(message : @posoco.Message) -> String {
  match message {
    @posoco.Message::UserMessage(content~) => {
      let parts : Array[String] = []
      for block in content {
        match block {
          @posoco.Content::Text(text) => parts.push(text)
          @posoco.Content::Image(..) => ()
        }
      }
      parts.join("\n")
    }
    _ => ""
  }
}

///|
/// Parse one delivered outcome envelope
/// `[posoco-task-outcome id=<id>] extension=<ext> label=<label>: <detail>`:
/// the detail is everything after the first `": "` that follows the `]`
/// marker, and its prefix maps to the state word ("timed out" → timed_out,
/// "cancelled" → cancelled, "failed: " → failed, everything else →
/// completed). The summary is always the full detail. Non-envelope text
/// parses to `None`.
fn parse_outcome_detail(text : String) -> (String, String)? {
  let after_marker = match text.split_once("[posoco-task-outcome id=") {
    Some((_, rest)) => rest
    None => return None
  }
  let after_id = match after_marker.split_once("] ") {
    Some((_, rest)) => rest
    None => return None
  }
  let detail = match after_id.split_once(": ") {
    Some((_, detail)) => detail.to_owned()
    None => return None
  }
  let word = if detail.has_prefix("timed out") {
    "timed_out"
  } else if detail.has_prefix("cancelled") {
    "cancelled"
  } else if detail.has_prefix("failed: ") {
    "failed"
  } else {
    "completed"
  }
  Some((word, detail))
}
