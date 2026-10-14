///|
/// Z.ai / BigModel platform endpoint presets for direct API access
/// (pay-as-you-go balance) on the Anthropic-compatible Messages route. The
/// GLM Coding Plan endpoints live in the coding-plan adaptor.
pub fn zai_platform_endpoint(platform : String) -> (String, String)? {
  match platform {
    "zai" => Some(("https://api.z.ai", "/api/anthropic"))
    "bigmodel" => Some(("https://open.bigmodel.cn", "/api/anthropic"))
    _ => None
  }
}

///|
/// Preset model ids in picker order. This is the whole model table: every id
/// (preset or discovered through `/models`) shares one uniform posture —
/// thinking is always enabled with a `reasoning_effort` of low|high|max, and
/// image input is never guessed for an undocumented id. Legacy generations
/// (GLM-4.x, GLM-5.2) are outside the supported set.
fn zai_preset_models() -> Array[String] {
  ["glm-5.3", "glm-5.3-flash"]
}

///|
/// Image-input capability per documented model id; the only per-model fact
/// this extension keeps.
fn zai_supports_images(model : String) -> Bool {
  model == "glm-5.3-flash"
}

///|
/// The uniform thinking-effort ladder. "off" is not offered: the Messages
/// endpoint keeps thinking enabled (forced-thinking models answer
/// `thinking: disabled` with HTTP 400).
pub fn zai_thinking_efforts() -> Array[String] {
  ["low", "high", "max"]
}

///|
/// Config for one model slot. `reasoning_effort` is always sent on the wire.
/// `context_window` is the host-declared model capacity in tokens; `None`
/// keeps every context figure unknown (unknown windows are never guessed).
/// `max_output_tokens` backs the Messages-required `max_tokens` field when
/// the host chat option omits it.
pub(all) struct ZaiConfig {
  api_key : String
  base_url : String
  model : String
  endpoint_prefix : String
  reasoning_effort : String
  context_window : Int32?
  max_output_tokens : Int32
} derive(Eq, Debug)

///|
pub extend ZaiConfig with Eq::{not_equal, equal}

///|
pub extend ZaiConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn ZaiConfig::ZaiConfig(
  api_key : String,
  model~ : String = "glm-5.3",
  base_url~ : String = "https://api.z.ai",
  endpoint_prefix~ : String = "/api/anthropic",
  reasoning_effort~ : String = "high",
  context_window~ : Int32? = None,
  max_output_tokens~ : Int32 = 32768,
) -> ZaiConfig {
  if !zai_thinking_efforts().contains(reasoning_effort) {
    abort("posoco-ext-zai: unsupported reasoning effort: " + reasoning_effort)
  }
  if context_window is Some(window) && window <= 0 {
    abort("posoco-ext-zai: context_window must be positive")
  }
  if max_output_tokens <= 0 {
    abort("posoco-ext-zai: max_output_tokens must be positive")
  }
  {
    api_key,
    base_url,
    model,
    endpoint_prefix,
    reasoning_effort,
    context_window,
    max_output_tokens,
  }
}

///|
/// Config for a model id under the uniform posture (default effort `high`).
pub fn ZaiConfig::for_model(
  api_key : String,
  model : String,
  base_url~ : String,
  endpoint_prefix~ : String,
  context_window~ : Int32? = None,
  max_output_tokens~ : Int32 = 32768,
) -> ZaiConfig {
  ZaiConfig(
    api_key,
    model~,
    base_url~,
    endpoint_prefix~,
    context_window~,
    max_output_tokens~,
  )
}

///|
/// Rebuild with a validated picker effort. "off" is a typed composition
/// error: the Messages endpoint keeps thinking enabled.
pub fn ZaiConfig::with_reasoning_effort(
  self : ZaiConfig,
  effort : String,
  manifest_id~ : String = "posoco_ext_zai",
) -> ZaiConfig raise @posoco.CompositionError {
  if !zai_thinking_efforts().contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id~,
      detail="unsupported reasoning effort: " +
        effort +
        " (thinking stays enabled; use low | high | max)",
    )
  }
  { ..self, reasoning_effort: effort, }
}

///|
pub(all) struct ZaiModelPort {
  config : ZaiConfig
  ctx : @devkit.ExtContext
}

///|
pub fn ZaiModelPort::ZaiModelPort(
  config : ZaiConfig,
  ctx~ : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> ZaiModelPort {
  { config, ctx, }
}
