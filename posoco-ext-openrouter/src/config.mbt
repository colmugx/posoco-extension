///|
/// Configuration for OpenRouterModelPort.
///
/// `api_key` and `model` are required; `base_url` defaults to the OpenRouter
/// production endpoint but stays overridable for tests and proxies. The
/// reasoning surface is the `include_reasoning` switch: thinking on sends
/// `"include_reasoning": true` so the response carries `reasoning_details`,
/// and a declared `reasoning_effort` level additionally sends the top-level
/// `reasoning_effort` field verbatim. Thinking off omits both fields entirely,
/// so the endpoint applies its own default. `thinking_efforts` lists the
/// levels the settings declared as selectable; empty means the surface is the
/// plain on/off toggle.
pub(all) struct OpenRouterConfig {
  /// API key sent as `Authorization: Bearer <api_key>`.
  api_key : String
  /// Model slug, e.g. "anthropic/claude-3.7-sonnet".
  model : String
  /// API root, e.g. "https://openrouter.ai/api/v1".
  base_url : String
  /// Current thinking toggle. On the wire, true encodes as
  /// `"include_reasoning": true`; false omits the field entirely (and
  /// `reasoning_effort` with it).
  thinking : Bool
  /// Currently selected effort level, sent verbatim as the top-level
  /// `reasoning_effort` field while thinking is enabled. None means plain
  /// toggle mode — only `include_reasoning` is sent, no effort value.
  reasoning_effort : String?
  /// Effort values the settings declare as selectable. Empty means the
  /// surface is off/on only. The picker-facing slot prepends the implicit
  /// "off" entry; it is never stored here.
  thinking_efforts : Array[String]
  /// Declared context capacity of `model`, in tokens. `None` = undeclared;
  /// auto-compact stays off for this model rather than guessing a window.
  context_window : Int?
  /// Declared auto-compact trigger point as a fraction of the context window,
  /// in (0, 1]. `None` = the host/core default (0.88) applies.
  compact_threshold : Double?
  /// Optional attribution header value sent as `HTTP-Referer`. Affects
  /// OpenRouter rankings attribution only, never inference behavior.
  http_referer : String?
  /// Optional attribution header value sent as `X-Title`.
  title : String?
  /// The model accepts image input (models discovery
  /// `architecture.input_modalities`). Image blocks then encode as typed
  /// content parts; otherwise they downgrade to explicit placeholders.
  supports_images : Bool
} derive(Eq, Debug)

///|
/// Config builder. `api_key` and `model` are required; `base_url` defaults to
/// the OpenRouter production endpoint.
pub fn OpenRouterConfig::OpenRouterConfig(
  api_key : String,
  model~ : String,
  base_url? : String = "https://openrouter.ai/api/v1",
  thinking? : Bool = false,
  reasoning_effort? : String? = None,
  thinking_efforts? : Array[String] = [],
  context_window? : Int? = None,
  compact_threshold? : Double? = None,
  http_referer? : String? = None,
  title? : String? = None,
  supports_images? : Bool = false,
) -> OpenRouterConfig {
  {
    api_key,
    model,
    base_url,
    thinking,
    reasoning_effort,
    thinking_efforts,
    context_window,
    compact_threshold,
    http_referer,
    title,
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
pub fn OpenRouterConfig::with_reasoning_effort(
  self : OpenRouterConfig,
  effort : String,
) -> OpenRouterConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, thinking: false, reasoning_effort: None }
  }
  if effort == "on" {
    if !self.thinking_efforts.is_empty() {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="unsupported reasoning effort: on (this endpoint declares explicit levels)",
      )
    }
    return { ..self, thinking: true, reasoning_effort: None }
  }
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_openrouter",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, thinking: true, reasoning_effort: Some(effort) }
}
