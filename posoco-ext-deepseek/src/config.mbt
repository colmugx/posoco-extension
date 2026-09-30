///|
/// Configuration for DeepSeekModelPort. Defaults target the standard
/// `https://api.deepseek.com` endpoint; FIM and prefix completion use the
/// `/beta` base_url variant.
pub(all) struct DeepSeekConfig {
  /// API key (DEEPSEEK environment variable by convention).
  api_key : String
  /// Base URL. Default: "https://api.deepseek.com".
  base_url : String
  /// Model id used for chat, FIM, and prefix completion.
  model : String
  /// Endpoint path prefix, e.g. "/v1" when base_url is "http://host:port".
  endpoint_prefix : String
  /// Provider-owned reasoning effort. Passed through verbatim; DeepSeek's
  /// server maps the requested effort level itself. The empty string means
  /// thinking is off; every other value must be on the uniform ladder from
  /// `deepseek_reasoning_efforts`.
  reasoning_effort : String
  /// Token budget ceiling reported to the host so auto-compact can size
  /// itself. None leaves auto-compact disabled — an unknown window is never
  /// guessed (the /models endpoint carries no context length).
  context_window : Int?
} derive(Eq, Debug)

///|
pub extend DeepSeekConfig with Eq::{not_equal, equal}

///|
pub extend DeepSeekConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DeepSeekConfig::DeepSeekConfig(
  api_key : String,
  model~ : String,
  base_url? : String = "https://api.deepseek.com",
  endpoint_prefix? : String = "",
  reasoning_effort? : String = "high",
  context_window? : Int? = None,
) -> DeepSeekConfig {
  if reasoning_effort != "" &&
    !deepseek_reasoning_efforts().contains(reasoning_effort) {
    abort(
      "posoco-ext-deepseek: unsupported reasoning effort: " + reasoning_effort,
    )
  }
  match context_window {
    Some(n) =>
      if n <= 0 {
        abort("posoco-ext-deepseek: context_window must be positive")
      }
    None => ()
  }
  {
    api_key,
    base_url,
    model,
    endpoint_prefix,
    reasoning_effort,
    context_window,
  }
}

///|
/// Rebuild a provider config with a validated effort value. The picker-facing
/// "off" entry maps to "" (thinking disabled on the wire); any other value
/// must be on the uniform provider ladder.
pub fn DeepSeekConfig::with_reasoning_effort(
  self : DeepSeekConfig,
  effort : String,
) -> DeepSeekConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, reasoning_effort: "", }
  }
  if !deepseek_reasoning_efforts().contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, reasoning_effort: effort, }
}

///|
pub(all) struct DeepSeekModelPort {
  config : DeepSeekConfig
  ctx : @devkit.ExtContext
}

///|
pub fn DeepSeekModelPort::DeepSeekModelPort(
  config : DeepSeekConfig,
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> DeepSeekModelPort {
  { config, ctx, }
}
