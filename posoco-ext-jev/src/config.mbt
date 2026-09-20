///|
/// Configuration for the TypeSafe Jev Decision API.
pub(all) struct JevConfig {
  /// TypeSafe API key, conventionally read by the host from TYPESAFE_API_KEY.
  api_key : String
  /// Jev model identifier. "jev-latest" tracks the current hosted model.
  model : String
  /// API base URL without the endpoint path.
  base_url : String
  /// Per-request timeout in milliseconds.
  timeout_ms : Int
} derive(Eq, Debug)

///|
pub fn JevConfig::JevConfig(
  api_key : String,
  model? : String = "jev-latest",
  base_url? : String = "https://api.typesafe.ai",
  timeout_ms? : Int = 30000,
) -> JevConfig {
  if api_key.trim().length() == 0 {
    abort("posoco-ext-jev: api_key must not be empty")
  }
  if model.trim().length() == 0 {
    abort("posoco-ext-jev: model must not be empty")
  }
  if base_url.trim().length() == 0 {
    abort("posoco-ext-jev: base_url must not be empty")
  }
  if timeout_ms <= 0 {
    abort("posoco-ext-jev: timeout_ms must be positive")
  }
  { api_key, model, base_url, timeout_ms, }
}

///|
/// Thin provider adapter. Consumer policy stays outside this type.
pub(all) struct JevDecisionPort {
  config : JevConfig
}

///|
pub fn JevDecisionPort::JevDecisionPort(config : JevConfig) -> JevDecisionPort {
  { config, }
}
