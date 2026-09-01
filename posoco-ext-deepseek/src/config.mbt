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
  /// Provider-owned reasoning effort. DeepSeek accepts `high` and `max`.
  reasoning_effort : String
  /// Effort values declared by the provider catalog for this model.
  thinking_efforts : Array[String]
  /// Token budget ceiling reported to the host so auto-compact can size
  /// itself. None leaves auto-compact disabled — an unknown window is never
  /// guessed (the /models endpoint carries no context length).
  context_window : Int?
} derive(Eq, Debug)

///|
/// Default config builder. api_key is required; other fields use defaults.
pub fn DeepSeekConfig::DeepSeekConfig(
  api_key : String,
  model? : String = "deepseek-v4-flash",
  base_url? : String = "https://api.deepseek.com",
  endpoint_prefix? : String = "",
  reasoning_effort? : String = "high",
  thinking_efforts? : Array[String] = ["high", "max"],
  context_window? : Int? = None,
) -> DeepSeekConfig {
  if (thinking_efforts.is_empty() && reasoning_effort != "") ||
    (
      !thinking_efforts.is_empty() &&
      reasoning_effort != "" &&
      !thinking_efforts.contains(reasoning_effort)
    ) {
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
    thinking_efforts,
    context_window,
  }
}

///|
/// Rebuild a provider config with a validated effort value. The picker-facing
/// "off" entry maps to "" (thinking disabled on the wire); any other value
/// must be one of the declared `thinking_efforts`.
pub fn DeepSeekConfig::with_reasoning_effort(
  self : DeepSeekConfig,
  effort : String,
) -> DeepSeekConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, reasoning_effort: "", }
  }
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, reasoning_effort: effort, }
}

///|
/// The DeepSeek ModelPort implementation. Implements @posoco.ModelPort for
/// chat/chat_streaming (standard trait path) and exposes DeepSeek-native APIs
/// (fim_completion, chat_prefix_completion) as extension methods.
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
