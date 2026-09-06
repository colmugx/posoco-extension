///|
/// Configuration for KimiModelPort.

///|
fn kimi_model_supported(model : String) -> Bool {
  model.has_prefix("kimi-k3") ||
  model.has_prefix("k3") ||
  model.has_prefix("kimi-for-coding")
}

///|
pub fn kimi_model_policy_error(model : String) -> String? {
  if kimi_model_supported(model) {
    None
  } else {
    Some(
      "model '" +
      model +
      "' was removed with the k2 line; use kimi-k3 (platform) or k3-256k / kimi-for-coding (coding plan)",
    )
  }
}

///|
pub(all) struct KimiConfig {
  /// API key (kimi environment variable by convention).
  api_key : String
  base_url : String
  model : String
  /// Endpoint path prefix, e.g. "/v1" when base_url is "http://host:port".
  endpoint_prefix : String
  /// Carried as the wire's `reasoning.effort`.
  reasoning_effort : String
  thinking_efforts : Array[String]
  identity_headers : Map[String, String]
  /// Context capacity in tokens; `None` = unknown.
  context_window : Int?
  /// Sends `prompt_cache_key` (derived from the session id).
  send_prompt_cache_key : Bool
} derive(Eq, Debug)

///|
pub fn KimiConfig::KimiConfig(
  api_key : String,
  model? : String = "kimi-k3",
  base_url? : String = "https://api.moonshot.ai/v1",
  endpoint_prefix? : String = "",
  reasoning_effort? : String = "high",
  thinking_efforts? : Array[String]? = None,
  identity_headers? : Map[String, String] = Map::from_array([]),
  context_window? : Int? = None,
  send_prompt_cache_key? : Bool = true,
) -> KimiConfig {
  match kimi_model_policy_error(model) {
    Some(message) => abort("posoco-ext-kimi: " + message)
    None => ()
  }
  let declared_efforts = match thinking_efforts {
    Some(values) => values
    None => kimi_effort_values(model)
  }
  if (declared_efforts.is_empty() && reasoning_effort != "") ||
    (
      !declared_efforts.is_empty() &&
      !declared_efforts.contains(reasoning_effort)
    ) {
    abort(
      "posoco-ext-kimi: unsupported reasoning effort '" +
      reasoning_effort +
      "' for model " +
      model,
    )
  }
  {
    api_key,
    base_url,
    model,
    endpoint_prefix,
    reasoning_effort,
    thinking_efforts: declared_efforts,
    identity_headers,
    context_window,
    send_prompt_cache_key,
  }
}

///|
/// The API-side default effort is max.
pub fn kimi_effort_values(model : String) -> Array[String] {
  if kimi_model_supported(model) {
    ["low", "high", "max"]
  } else {
    []
  }
}

///|
pub fn KimiConfig::with_reasoning_effort(
  self : KimiConfig,
  effort : String,
) -> KimiConfig raise @posoco.CompositionError {
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_kimi",
      detail="unsupported reasoning effort '" +
        effort +
        "' for model " +
        self.model,
    )
  }
  { ..self, reasoning_effort: effort, }
}

///|
pub fn KimiConfig::from_oauth_credential(
  credential : @oauth.Credential,
  model : String,
  endpoint_prefix? : String = "",
  reasoning_effort? : String = "high",
  thinking_efforts? : Array[String]? = None,
  identity_headers? : Map[String, String] = Map::from_array([]),
) -> KimiConfig {
  KimiConfig(
    credential.access_token,
    model~,
    base_url=kimi_oauth_api_base(),
    endpoint_prefix~,
    reasoning_effort~,
    thinking_efforts~,
    identity_headers~,
  )
}

///|
pub(all) struct KimiModelPort {
  config : KimiConfig
  ctx : @devkit.ExtContext
  mut prompt_cache_key_rejected : Bool
}

///|
pub fn KimiModelPort::KimiModelPort(
  config : KimiConfig,
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> KimiModelPort {
  { config, ctx, prompt_cache_key_rejected: false, }
}
