///|
/// ModelPort for the GLM Coding Plan: the shared GLM protocol pointed at a
/// coding-plan endpoint, carrying the coding-plan extension identity.
pub(all) struct ZaiCodingPlanModelPort {
  inner : @zai.ZaiModelPort
}

///|
pub fn ZaiCodingPlanModelPort::ZaiCodingPlanModelPort(
  config : @zai.ZaiConfig,
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> ZaiCodingPlanModelPort {
  { inner: @zai.ZaiModelPort(config, ctx~), }
}

///|
pub impl @posoco.ModelPort for ZaiCodingPlanModelPort with fn chat(
  self : ZaiCodingPlanModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let port : &@posoco.ModelPort = self.inner
  port.chat(scope, messages, tools, options, stream)
}

///|
pub impl @posoco.ModelPort for ZaiCodingPlanModelPort with fn compact(
  self : ZaiCodingPlanModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  options : @posoco.ChatOptions,
  trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let port : &@posoco.ModelPort = self.inner
  port.compact(scope, messages, options, trigger)
}

///|
pub impl @posoco.ModelPort for ZaiCodingPlanModelPort with fn provider_config(
  self : ZaiCodingPlanModelPort,
) -> @posoco.ProviderConfig {
  let port : &@posoco.ModelPort = self.inner
  port.provider_config()
}

///|
pub impl @posoco.Extension for ZaiCodingPlanModelPort with fn extension_id(
  _self : ZaiCodingPlanModelPort,
) -> String {
  "posoco_ext_zai_coding_plan"
}

///|
pub impl @posoco.Extension for ZaiCodingPlanModelPort with fn manifest(
  self : ZaiCodingPlanModelPort,
) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_zai_coding_plan",
    models: [self],
    tools: [],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
pub extend ZaiCodingPlanModelPort with @posoco.Extension::{
  extension_id,
  manifest,
}
