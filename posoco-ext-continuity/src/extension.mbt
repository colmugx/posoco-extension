let candidate_notice_prefix : String = "[SESSION_CONTINUITY_CANDIDATE]"

///|
/// Session Continuity extension.
///
/// One instance is exposed through multiple Posoco port views so canonical
/// model scope, transcript interception, tool execution and observer lifecycle
/// share the same continuity state. Posoco itself remains unaware of
/// continuity semantics.
pub struct ContinuityExtension {
  inner_model : &@posoco.ModelPort
  config : ContinuityConfig
  prompt : ContinuityPrompt
  archive : InMemoryContinuityArchive
  checkpoint_counts : Map[String, Int]
  mut active_session_id : String?
  mut active_run_id : String?
  mut turn_active : Bool
  mut candidate : RuntimeCandidate?
  mut prepared : PreparedCheckpoint?
  mut candidate_seq : Int
  mut checkpoint_seq : Int
}

///|
pub fn ContinuityExtension::new(
  inner_model : &@posoco.ModelPort,
  config? : ContinuityConfig = ContinuityConfig::default(),
) -> ContinuityExtension {
  {
    inner_model,
    config,
    prompt: ContinuityPrompt::new(),
    archive: InMemoryContinuityArchive::new(),
    checkpoint_counts: Map::from_array([]),
    active_session_id: None,
    active_run_id: None,
    turn_active: false,
    candidate: None,
    prepared: None,
    candidate_seq: 0,
    checkpoint_seq: 0,
  }
}

///|
pub fn continuity_extension(
  model : &@posoco.ModelPort,
  config? : ContinuityConfig = ContinuityConfig::default(),
) -> ContinuityExtension {
  ContinuityExtension::new(model, config~)
}

///|
pub fn ContinuityExtension::current_session_id(
  self : ContinuityExtension,
) -> String? {
  self.active_session_id
}

///|
pub fn ContinuityExtension::current_run_id(
  self : ContinuityExtension,
) -> String? {
  self.active_run_id
}

///|
pub fn ContinuityExtension::is_turn_active(self : ContinuityExtension) -> Bool {
  self.turn_active
}

fn candidate_notice(candidate : RuntimeCandidate) -> @posoco.Message {
  @posoco.Message::SystemMessage(content=[
    @posoco.Content::Text(
      candidate_notice_prefix +
      "\nA settled historical segment is eligible for checkpointing.\n" +
      "candidate_id: " + candidate.id + "\n" +
      "estimated_tokens: \{candidate.estimated_tokens}\n\n" +
      "If this historical work is sufficiently settled, call session_checkpoint. " +
      "The candidate range is system-selected; preserve completed work, decisions, " +
      "artifacts, exact facts and unresolved threads."
    ),
  ])
}

fn is_candidate_notice(message : @posoco.Message) -> Bool {
  match message {
    @posoco.Message::SystemMessage(content=[@posoco.Content::Text(text), ..]) =>
      text.has_prefix(candidate_notice_prefix)
    _ => false
  }
}

fn remove_candidate_notices(
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  let out : Array[@posoco.Message] = []
  for message in messages {
    if !is_candidate_notice(message) { out.push(message) }
  }
  out
}

fn make_runtime_candidate(
  self : ContinuityExtension,
  scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
  planned : CheckpointCandidate,
) -> RuntimeCandidate {
  self.candidate_seq = self.candidate_seq + 1
  {
    id: "cc_\{self.candidate_seq}",
    session_id: scope.session_id.to_string(),
    run_id: scope.run_id.to_string(),
    start_index: planned.start_index,
    end_index: planned.end_index,
    estimated_tokens: planned.estimated_tokens,
    source_messages: copy_message_range(
      messages,
      planned.start_index,
      planned.end_index,
    ),
  }
}

///|
/// ModelPort owns only scope-aware candidate presentation. The actual
/// canonical transcript rewrite remains in Hook. Candidate notices are
/// ephemeral provider input and are removed from `processed_messages` before
/// returning to Posoco.
pub impl @posoco.ModelPort for ContinuityExtension with fn chat(
  self,
  scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.active_session_id = Some(scope.session_id.to_string())
  self.active_run_id = Some(scope.run_id.to_string())
  let provider_messages = messages.copy()
  if self.prepared is None {
    let plan = plan_continuity(messages, self.config.context_window, self.config)
    match plan.candidate {
      Some(planned) => {
        let candidate = make_runtime_candidate(self, scope, messages, planned)
        self.candidate = Some(candidate)
        provider_messages.push(candidate_notice(candidate))
      }
      None => self.candidate = None
    }
  }
  let result = self.inner_model.chat(
    scope,
    provider_messages,
    tools,
    options,
    stream,
  )
  @posoco.ModelCallResult::{
    completion: result.completion,
    processed_messages: remove_candidate_notices(result.processed_messages),
  }
}

///|
pub impl @posoco.ModelPort for ContinuityExtension with fn compact(
  self,
  scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
  options : @posoco.ChatOptions,
  trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  self.active_session_id = Some(scope.session_id.to_string())
  self.active_run_id = Some(scope.run_id.to_string())
  self.inner_model.compact(scope, messages, options, trigger)
}

///|
pub impl @posoco.ModelPort for ContinuityExtension with fn provider_config(
  self,
) -> @posoco.ProviderConfig {
  self.inner_model.provider_config()
}

fn mark_checkpoint_committed(
  self : ContinuityExtension,
  session_id : String,
) -> Unit {
  let prior = match self.checkpoint_counts.get(session_id) {
    Some(value) => value
    None => 0
  }
  self.checkpoint_counts[session_id] = prior + 1
}

///|
/// Hook owns the canonical transcript rewrite. A prepared checkpoint is
/// applied only when both invocation identity and the original source range
/// still match exactly. Otherwise the transcript is left untouched.
pub impl @posoco.Hook for ContinuityExtension with fn before_model(
  self,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] raise @posoco.HookAbort {
  match self.prepared {
    None => messages
    Some(prepared) => {
      let identity_matches = match (self.active_session_id, self.active_run_id) {
        (Some(session_id), Some(run_id)) =>
          session_id == prepared.candidate.session_id &&
          run_id == prepared.candidate.run_id
        _ => false
      }
      if !identity_matches {
        self.prepared = None
        self.candidate = None
        return messages
      }
      match apply_prepared_checkpoint(messages, prepared) {
        None => {
          // Archive already exists, but canonical history is never removed
          // when the source range has changed.
          self.prepared = None
          self.candidate = None
          messages
        }
        Some(rewritten) => {
          mark_checkpoint_committed(self, prepared.candidate.session_id)
          self.prepared = None
          self.candidate = None
          rewritten
        }
      }
    }
  }
}

///|
/// Effect-level post events are intentionally read-only. They are available
/// for later metrics and diagnostics; checkpoint state transitions happen at
/// the explicit tool and pre-model boundaries instead.
pub impl @posoco.Hook for ContinuityExtension with fn on_post_event(
  _self,
  _stage : @posoco.HookStage,
) -> Unit {
  ()
}

fn clear_transient_turn_state(self : ContinuityExtension) -> Unit {
  self.active_session_id = None
  self.active_run_id = None
  self.candidate = None
  self.prepared = None
}

///|
/// Observer owns turn-level lifecycle only. It never supplies execution
/// identity; canonical identity comes from InvocationScope on ModelPort.
pub impl @posoco.Observer for ContinuityExtension with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => {
      clear_transient_turn_state(self)
      self.turn_active = true
    }
    @posoco.TurnEvent::TurnCompleted | @posoco.TurnEvent::TurnFailed(_) => {
      self.turn_active = false
      clear_transient_turn_state(self)
    }
    @posoco.TurnEvent::SessionRedirect(..) => {
      clear_transient_turn_state(self)
    }
    _ => ()
  }
}

///|
pub impl @posoco.Extension for ContinuityExtension with fn extension_id(
  _self,
) -> String {
  "posoco_ext_continuity"
}

///|
pub impl @posoco.Extension for ContinuityExtension with fn manifest(
  self,
) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_continuity",
    models: [self],
    tools: [self],
    sessions: [],
    observers: [self],
    hooks: [self],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [self.prompt],
  }
}

///|
pub extend ContinuityExtension with @posoco.Extension::{extension_id, manifest}
