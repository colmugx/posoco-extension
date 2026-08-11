///|
/// Session Continuity extension.
///
/// One instance is exposed through multiple Posoco port views so model scope,
/// hook interception, observer lifecycle and prompt policy share the same
/// continuity state. Posoco itself remains unaware of continuity semantics.
pub struct ContinuityExtension {
  inner_model : &@posoco.ModelPort
  config : ContinuityConfig
  prompt : ContinuityPrompt
  mut active_session_id : String?
  mut active_run_id : String?
  mut turn_active : Bool
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
    active_session_id: None,
    active_run_id: None,
    turn_active: false,
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

///|
/// The model port is only a scope-aware decorator. Transcript planning stays
/// in Hook; this layer records Posoco's canonical invocation identity and then
/// delegates to the configured model unchanged.
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
  self.inner_model.chat(scope, messages, tools, options, stream)
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

///|
/// Hook owns transcript behavior. The initial implementation is deliberately
/// pass-through while the planner/checkpoint commit path is wired on top of
/// Posoco's canonical TranscriptRewrite semantics.
pub impl @posoco.Hook for ContinuityExtension with fn before_model(
  _self,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] raise @posoco.HookAbort {
  messages
}

///|
/// Effect-level post events are available here for checkpoint/tool bookkeeping.
pub impl @posoco.Hook for ContinuityExtension with fn on_post_event(
  _self,
  _stage : @posoco.HookStage,
) -> Unit {
  ()
}

///|
/// Observer owns turn-level lifecycle only. It does not infer session identity;
/// that identity comes from InvocationScope on the model port.
pub impl @posoco.Observer for ContinuityExtension with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => self.turn_active = true
    @posoco.TurnEvent::TurnCompleted | @posoco.TurnEvent::TurnFailed(_) => {
      self.turn_active = false
      self.active_run_id = None
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
    tools: [],
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
