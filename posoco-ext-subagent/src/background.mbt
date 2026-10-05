///|
/// Background bookkeeping for the core task capability: the child registry
/// backing `resume` and the domain projection of delivered background
/// outcomes. The extension owns no delivery machinery — core routes every
/// background terminal into the parent session's inbox, and the result
/// surfaces as a user message in the session's next ordinary turn. The
/// extension's jobs are the declaration-only `background_exited` event at
/// true task exit (hosts/observers learn a death immediately; the runner
/// does no bookkeeping there), observation at the delivery point
/// (`before_model`) plus the authoritative `background_terminal` event
/// hosts listen for.

///|
/// Registry entry state for one spawned child: `Running` from spawn until
/// the delivery-point observation records the state word and the final
/// summary text (foreground and background alike — both advertise the id in
/// their footer). The summary is read back by hosts/tests through the
/// registry itself.
#warnings("-unused_field")
priv enum BackgroundRecordState {
  Running
  Done(String, String)
}

///|
priv struct BackgroundRecord {
  /// Kind preset the child was spawned with (subscription event payload).
  kind : String
  mut state : BackgroundRecordState
}

///|
fn BackgroundRecord::BackgroundRecord(kind~ : String) -> BackgroundRecord {
  { kind, state: Running, }
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
/// session id + state word ("running" / "completed" / "failed" /
/// "timed_out" / "cancelled"), in spawn order.
pub fn SubagentTools::background_children(
  self : SubagentTools,
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for id, record in self.registry {
    let word = match record.state {
      Running => "running"
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
  _self : SubagentTools,
) {
  ()
}

///|
impl @posoco.Observer for SubagentTools with fn on_event(
  _self : SubagentTools,
  _event : @posoco.TurnEvent,
) -> Unit {
  ()
}

///|
/// Track the parent session from scoped events: a background task's result
/// is addressed to the session whose turn spawned it. Out-of-run events
/// (scope `None`) go to the wakeup policy — core's ready projection carries
/// no scope, session attribution travels in the event data.
impl @posoco.Observer for SubagentTools with fn on_event_at(
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
/// model input is scanned here first and returned unchanged.
impl @posoco.PipelineHook for SubagentTools with fn before_model(
  self : SubagentTools,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] raise @posoco.HookAbort {
  self.observe_deliveries(messages)
  messages
}

///|
/// Scan the model input for delivered background outcomes (ruling: terminal
/// observation lives at the delivery point). For every still-unobserved
/// receipt id, a matching `[posoco-task-outcome id=<id>]` envelope updates
/// the registry record, fires the `background_terminal` subscription event,
/// and leaves the unobserved set — re-delivery scans are then no-ops.
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
      match parse_outcome_detail(text) {
        Some((state_word, summary)) =>
          self.record_terminal(child_session, state_word, summary)
        None => ()
      }
    }
  }
}

///|
/// Registry update at the delivery point: only a record that exists and is
/// still `Running` transitions to `Done` (idempotent against re-delivery
/// scans), and the terminal event fires exactly once per child.
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
    Running => ()
    Done(_) => return
  }
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
