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
  /// Product identity headers (User-Agent + X-Msh-*). Populated by the
  /// provider factory when impersonating kimi-code-cli; merged under the
  /// Authorization/Content-Type chat headers so the chat wire contract wins.
  identity_headers : Map[String, String]
  /// Context capacity reported by the /models discovery endpoint, in tokens.
  /// `None` = unknown; auto-compact stays off rather than guessing.
  context_window : Int?
  /// The model accepts image input (models discovery `supports_image_in`).
  /// Image blocks then encode as typed content parts; otherwise they
  /// downgrade to explicit placeholders.
  supports_images : Bool
  /// Send `prompt_cache_key` (derived from the session id) on chat requests.
  /// Moonshot's API defines the parameter natively, so this defaults to true;
  /// hosts opt out with false.
  send_prompt_cache_key : Bool
} derive(Eq, Debug)

///|
/// Default config builder. api_key is required; other fields use defaults.
pub fn KimiConfig::KimiConfig(
  api_key : String,
  model? : String = "kimi-k2.7-code",
  base_url? : String = "https://api.moonshot.ai/v1",
  endpoint_prefix? : String = "",
  reasoning_effort? : String = "high",
  thinking_efforts? : Array[String]? = None,
  identity_headers? : Map[String, String] = Map::from_array([]),
  context_window? : Int? = None,
  supports_images? : Bool = false,
  send_prompt_cache_key? : Bool = true,
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
    identity_headers,
    context_window,
    supports_images,
    send_prompt_cache_key,
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
  { ..self, reasoning_effort: effort, }
}

///|
/// Build the provider-owned OAuth transport configuration. Hosts should pass
/// the opaque credential and model id here instead of selecting the `/coding`
/// endpoint themselves. `identity_headers` carries the product identity set
/// (User-Agent + X-Msh-*) the provider needs to impersonate kimi-code-cli for
/// the managed endpoint.
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
/// The Kimi ModelPort implementation. Implements @posoco.ModelPort for
/// chat and streaming chat. Kimi does not expose a FIM capability.
pub(all) struct KimiModelPort {
  config : KimiConfig
  ctx : @devkit.ExtContext
  /// Set when a provider error body explicitly rejected prompt_cache_key;
  /// later chat requests then omit the key. Per-process only, never
  /// persisted.
  mut prompt_cache_key_rejected : Bool
}

///|
pub fn KimiModelPort::KimiModelPort(
  config : KimiConfig,
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> KimiModelPort {
  { config, ctx, prompt_cache_key_rejected: false, }
}
