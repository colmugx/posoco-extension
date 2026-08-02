///|
/// Configuration for KimiModelPort. Defaults target the standard
/// `https://api.kimi.com` endpoint; FIM and prefix completion use the
/// `/beta` base_url variant.
pub(all) struct KimiConfig {
  /// API key (kimi environment variable by convention).
  api_key : String
  /// Base URL. Default: "https://api.kimi.com".
  base_url : String
  /// Model id used for chat, FIM, and prefix completion.
  model : String
  /// Endpoint path prefix, e.g. "/v1" when base_url is "http://host:port".
  endpoint_prefix : String
} derive(Eq, Debug)

///|
/// Default config builder. api_key is required; other fields use defaults.
pub fn KimiConfig::new(
  api_key : String,
  model? : String = "kimi-v4-flash",
  base_url? : String = "https://api.kimi.com",
  endpoint_prefix? : String = "",
) -> KimiConfig {
  { api_key, base_url, model, endpoint_prefix }
}

///|
/// The kimi ModelPort implementation. Implements @posoco.ModelPort for
/// chat/chat_streaming (standard trait path) and exposes kimi-native APIs
/// (fim_completion, chat_prefix_completion) as extension methods.
pub(all) struct KimiModelPort {
  config : KimiConfig
  ctx : @devkit.ExtContext
}

///|
pub fn KimiModelPort::new(
  config : KimiConfig,
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> KimiModelPort {
  { config, ctx }
}
