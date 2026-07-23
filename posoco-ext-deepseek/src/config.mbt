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
} derive(Eq, Debug)

///|
/// Default config builder. api_key is required; other fields use defaults.
pub fn DeepSeekConfig::new(
  api_key : String,
  model? : String = "deepseek-v4-flash",
  base_url? : String = "https://api.deepseek.com",
  endpoint_prefix? : String = "",
) -> DeepSeekConfig {
  { api_key, base_url, model, endpoint_prefix }
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
pub fn DeepSeekModelPort::new(
  config : DeepSeekConfig,
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> DeepSeekModelPort {
  { config, ctx }
}
