///|
/// config.mbt — per-slot configuration for a custom provider.
///
/// `base_url` and `model` are required: this extension exists to reach
/// endpoints the user declares, so it has no vendor default. `protocol` says
/// which wire the endpoint speaks; `auth` says how the credential rides on
/// that wire. Every other field shapes the catalog entry or one wire request.

///|
/// How the API key is presented on the wire. `Auto` follows the protocol's
/// convention (Bearer for the two OpenAI wires, `x-api-key` for Messages);
/// the explicit values exist because private gateways regularly deviate.
pub(all) enum CustomAuth {
  /// Bearer on `chat_completions`/`responses`, `x-api-key` on `messages`.
  Auto
  /// `Authorization: Bearer <key>` on every wire.
  Bearer
  /// `x-api-key: <key>` on every wire.
  ApiKeyHeader
} derive(Eq, Debug)

///|
pub extend CustomAuth with Eq::{not_equal, equal}

///|
pub extend CustomAuth with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn CustomAuth::to_id(self : CustomAuth) -> String {
  match self {
    Auto => "auto"
    Bearer => "bearer"
    ApiKeyHeader => "x_api_key"
  }
}

///|
pub fn custom_auth_of_id(id : String) -> CustomAuth? {
  match id {
    "auto" => Some(Auto)
    "bearer" => Some(Bearer)
    "x_api_key" => Some(ApiKeyHeader)
    _ => None
  }
}

///|
pub fn custom_auth_choices() -> String {
  "auto, bearer, x_api_key"
}

///|
/// Default `max_tokens` for the Messages wire. Messages requires the field and
/// this extension has no way to infer a ceiling, so the default is declared
/// here and documented instead of being guessed at request time.
pub const CUSTOM_DEFAULT_MAX_OUTPUT_TOKENS : Int32 = 8192

///|
pub(all) struct CustomConfig {
  /// API key sent according to `auth`.
  api_key : String
  /// Base URL, e.g. "https://llm.internal.example/v1".
  base_url : String
  /// Endpoint path prefix, e.g. "/v1" when base_url is a bare host.
  endpoint_prefix : String
  /// Model id this config serves.
  model : String
  /// Wire dialect: chat completions, responses, or messages.
  protocol : CustomProtocol
  /// Credential placement on the wire (see `CustomAuth`).
  auth : CustomAuth
  /// `max_tokens` for the Messages wire (the other wires send the turn's
  /// `max_output_tokens` only when the caller supplied one).
  max_output_tokens : Int32
  /// Selected effort level; None omits the wire's reasoning surface.
  reasoning_effort : String?
  /// Declared selectable effort levels. The slot prepends the implicit
  /// "off" entry for the picker; it is never stored here.
  thinking_efforts : Array[String]
  /// Declared context capacity of `model`, in tokens.
  context_window : Int32?
  /// Declared auto-compact trigger as a fraction of the context window.
  compact_threshold : Double?
  /// Declares that `model` accepts image input; otherwise images downgrade to
  /// an explicit placeholder.
  supports_images : Bool
  /// Opts in to a provider-side `prompt_cache_key` on the chat-completions
  /// wire, derived from the session id.
  send_prompt_cache_key : Bool
} derive(Eq, Debug)

///|
pub extend CustomConfig with Eq::{not_equal, equal}

///|
pub extend CustomConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Config builder. `api_key`, `base_url`, and `model` are required; the
/// protocol defaults to the chat-completions wire, which is what every
/// pre-protocol settings entry means.
pub fn CustomConfig::CustomConfig(
  api_key : String,
  base_url~ : String,
  model~ : String,
  endpoint_prefix~ : String = "",
  protocol~ : CustomProtocol = CustomProtocol::ChatCompletions,
  auth~ : CustomAuth = CustomAuth::Auto,
  max_output_tokens~ : Int32 = CUSTOM_DEFAULT_MAX_OUTPUT_TOKENS,
  reasoning_effort~ : String? = None,
  thinking_efforts~ : Array[String] = [],
  context_window~ : Int32? = None,
  compact_threshold~ : Double? = None,
  supports_images~ : Bool = false,
  send_prompt_cache_key~ : Bool = false,
) -> CustomConfig {
  {
    api_key,
    base_url,
    model,
    endpoint_prefix,
    protocol,
    auth,
    max_output_tokens,
    reasoning_effort,
    thinking_efforts,
    context_window,
    compact_threshold,
    supports_images,
    send_prompt_cache_key,
  }
}

///|
/// Replace the credential. A record update, so a field added later reaches
/// every rebuild site automatically instead of being silently dropped.
pub fn CustomConfig::with_api_key(
  self : CustomConfig,
  api_key : String,
) -> CustomConfig {
  { ..self, api_key, }
}

///|
/// Rebuild a config with a validated selector value.
///
/// "off" and "on" both select omission ("on" is a legacy alias so stored
/// settings keep composing) and "on" is rejected while explicit levels are
/// declared; any other value must be one of the declared `thinking_efforts`
/// and sends that level verbatim.
pub fn CustomConfig::with_reasoning_effort(
  self : CustomConfig,
  effort : String,
) -> CustomConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, reasoning_effort: None, }
  }
  if effort == "on" {
    if !self.thinking_efforts.is_empty() {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="unsupported reasoning effort: on (this endpoint declares explicit levels)",
      )
    }
    return { ..self, reasoning_effort: None, }
  }
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_custom",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, reasoning_effort: Some(effort), }
}

///|
/// Replace the protocol (used by tests and by hosts that rebuild a config
/// from cached records).
pub fn CustomConfig::with_protocol(
  self : CustomConfig,
  protocol : CustomProtocol,
) -> CustomConfig {
  { ..self, protocol, }
}
