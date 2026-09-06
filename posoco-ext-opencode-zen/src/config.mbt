///|
/// Zen's upstream speaks a GLM-flavored OpenAI Chat Completions dialect:
/// `thinking: {"type": "enabled"}`, top-level `reasoning_effort`, and
/// `reasoning_content` echoed on assistant messages.

///|
/// Configuration for OpenCodeZenModelPort. `endpoint_prefix` stays empty
/// for Zen because its base URL already carries `/v1`.
pub(all) struct OpenCodeZenConfig {
  /// API key sent as `Authorization: Bearer <api_key>`.
  api_key : String
  /// Base URL, conventionally "https://opencode.ai/zen/v1".
  base_url : String
  /// Endpoint path prefix; empty for Zen (the base URL carries `/v1`).
  endpoint_prefix : String
  /// Model id used for chat.
  model : String
  /// Thinking toggle; false omits the wire fields entirely.
  thinking : Bool
  /// Selected effort level, sent verbatim while thinking is enabled.
  reasoning_effort : String?
  /// Selectable effort levels (efforts.mbt preset table); empty = off/on only.
  thinking_efforts : Array[String]
  /// Declared context capacity of `model`, in tokens. `None` = undeclared;
  /// auto-compact stays off for this model rather than guessing a window.
  context_window : Int?
  /// Declared auto-compact trigger point as a fraction of the context window,
  /// in (0, 1]. `None` = the host/core default applies.
  compact_threshold : Double?
  /// Declares that `model` accepts image input. When true, messages carrying
  /// Image blocks encode as typed content parts; when false, images downgrade
  /// to an explicit placeholder instead of being sent or silently dropped.
  supports_images : Bool
} derive(Eq, Debug)

///|
/// Config builder. `api_key`, `base_url`, and `model` are required.
pub fn OpenCodeZenConfig::OpenCodeZenConfig(
  api_key : String,
  base_url~ : String,
  model~ : String,
  endpoint_prefix? : String = "",
  thinking? : Bool = false,
  reasoning_effort? : String? = None,
  thinking_efforts? : Array[String] = [],
  context_window? : Int? = None,
  compact_threshold? : Double? = None,
  supports_images? : Bool = false,
) -> OpenCodeZenConfig {
  {
    api_key,
    base_url,
    model,
    endpoint_prefix,
    thinking,
    reasoning_effort,
    thinking_efforts,
    context_window,
    compact_threshold,
    supports_images,
  }
}

///|
/// Rebuild a provider config with a validated selector value.
///
/// The picker-facing vocabulary: "off" disables thinking (no effort field);
/// "on" enables thinking without an effort level and exists only while no
/// levels are declared; any other value must be one of the declared
/// `thinking_efforts` and enables thinking with that level sent verbatim.
pub fn OpenCodeZenConfig::with_reasoning_effort(
  self : OpenCodeZenConfig,
  effort : String,
) -> OpenCodeZenConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, thinking: false, reasoning_effort: None, }
  }
  if effort == "on" {
    if !self.thinking_efforts.is_empty() {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_zen",
        detail="unsupported reasoning effort: on (this endpoint declares explicit levels)",
      )
    }
    return { ..self, thinking: true, reasoning_effort: None, }
  }
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_opencode_zen",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, thinking: true, reasoning_effort: Some(effort), }
}

///|
/// Bearer auth plus JSON content type, then the per-request OpenCode routing
/// metadata.
fn build_headers(config : OpenCodeZenConfig) -> @http.Headers {
  let headers : @http.Headers = {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
  for key, value in zen_request_headers() {
    headers[@http.CaseInsensitiveString(key)] = value
  }
  headers
}

///|
fn chat_url(config : OpenCodeZenConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
/// The Zen ModelPort implementation.
pub(all) struct OpenCodeZenModelPort {
  config : OpenCodeZenConfig
}

///|
pub fn OpenCodeZenModelPort::OpenCodeZenModelPort(
  config : OpenCodeZenConfig,
) -> OpenCodeZenModelPort {
  { config, }
}

///|
/// Reasoning levels come from the slot, not from provider_config; only the
/// auto-compact metadata is reported.
pub impl @posoco.ModelPort for OpenCodeZenModelPort with fn provider_config(
  self : OpenCodeZenModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=self.config.compact_threshold,
  )
}
