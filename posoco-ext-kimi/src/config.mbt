///|
/// Configuration for KimiModelPort. API-key mode defaults to the public
/// Moonshot Open Platform endpoint; managed OAuth uses the provider's coding
/// endpoint via `from_oauth_credential`.
pub(all) struct KimiConfig {
  /// API key (kimi environment variable by convention).
  api_key : String
  /// Base URL. API-key mode defaults to the Moonshot Open Platform endpoint.
  base_url : String
  /// Model id used for chat.
  model : String
  /// Endpoint path prefix, e.g. "/v1" when base_url is "http://host:port".
  endpoint_prefix : String
  /// Provider-owned reasoning effort.
  reasoning_effort : String
  /// Effort values declared by the provider model catalog.
  thinking_efforts : Array[String]
} derive(Eq, Debug)

///|
/// Default config builder. api_key is required; other fields use defaults.
pub fn KimiConfig::new(
  api_key : String,
  model? : String = "kimi-v4-flash",
  base_url? : String = "https://api.moonshot.ai/v1",
  endpoint_prefix? : String = "",
  reasoning_effort? : String = "high",
  thinking_efforts? : Array[String]? = None,
) -> KimiConfig {
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
  }
}

///|
/// Kimi effort capabilities are provider-owned and vary by model family.
pub fn kimi_effort_values(model : String) -> Array[String] {
  if model == "kimi-k3" {
    ["low", "high", "max"]
  } else if model == "kimi-k2.7-code" {
    ["high", "max"]
  } else if model == "kimi-k2.6" || model == "kimi-k2.5" {
    ["low", "high", "max"]
  } else {
    ["high", "max"]
  }
}

///|
/// Rebuild a Kimi config with provider-validated effort.
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
  { ..self, reasoning_effort: effort }
}

///|
/// Build the provider-owned OAuth transport configuration. Hosts should pass
/// the opaque credential and model id here instead of selecting the `/coding`
/// endpoint themselves.
pub fn KimiConfig::from_oauth_credential(
  credential : @oauth.Credential,
  model : String,
  endpoint_prefix? : String = "",
  reasoning_effort? : String = "high",
  thinking_efforts? : Array[String]? = None,
) -> KimiConfig {
  KimiConfig::new(
    credential.access_token,
    model~,
    base_url=kimi_oauth_api_base(),
    endpoint_prefix~,
    reasoning_effort~,
    thinking_efforts~,
  )
}

///|
/// The Kimi ModelPort implementation. Implements @posoco.ModelPort for
/// chat and streaming chat. Kimi does not expose a FIM capability.
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
