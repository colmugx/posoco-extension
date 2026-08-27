///|
/// Configuration for OpenAICompatibleModelPort.
///
/// `base_url` and `model` are required — this adapter exists to reach custom
/// endpoints, so it deliberately has no vendor default. `endpoint_prefix` is
/// optional because most `/v1` servers already bake the version into base_url;
/// pass `/v1` only when base_url is a bare host.
///
/// Reasoning surface: when thinking is enabled the request carries the object
/// form `thinking: {"type": "enabled"}` (never a bare boolean), and a declared
/// `reasoning_effort` level additionally sends the top-level `reasoning_effort`
/// field verbatim. When thinking is off both fields are omitted entirely, so
/// the endpoint applies its own default. `thinking_efforts` lists the levels
/// the settings declared as selectable; empty means the surface is the plain
/// on/off toggle.
pub(all) struct OpenAICompatibleConfig {
  /// API key sent as `Authorization: Bearer <api_key>`.
  api_key : String
  /// Base URL, e.g. "https://dashscope.aliyuncs.com/compatible-mode/v1".
  base_url : String
  /// Endpoint path prefix, e.g. "/v1" when base_url is "http://host:port".
  endpoint_prefix : String
  /// Model id used for chat.
  model : String
  /// Current thinking toggle. On the wire, true encodes as the object form
  /// `thinking: {"type": "enabled"}`; false omits the `thinking` field
  /// entirely (and `reasoning_effort` with it).
  thinking : Bool
  /// Currently selected effort level, sent verbatim as the top-level
  /// `reasoning_effort` field while thinking is enabled. None means plain
  /// toggle mode — only the `thinking` object is sent, no effort value.
  reasoning_effort : String?
  /// Effort values the endpoint declares as selectable (from the settings
  /// `reasoning_effort` array). Empty means the surface is off/on only. The
  /// picker-facing slot prepends the implicit "off" entry; it is never stored
  /// here.
  thinking_efforts : Array[String]
  /// Declared context capacity of `model`, in tokens (settings
  /// `models[].context_window`). `None` = undeclared; auto-compact stays off
  /// for this model rather than guessing a window.
  context_window : Int?
  /// Declared auto-compact trigger point as a fraction of the context window,
  /// in (0, 1] (settings `models[].compact_threshold`). `None` = the
  /// host/core default (0.88) applies.
  compact_threshold : Double?
  /// Declares that `model` accepts image input (settings
  /// `image_input` / `models[].image_input`). When true, messages carrying
  /// Image blocks encode as typed content parts; when false, images downgrade
  /// to an explicit placeholder instead of being sent or silently dropped.
  supports_images : Bool
} derive(Eq, Debug)

///|
/// Config builder. `api_key`, `base_url`, and `model` are required.
pub fn OpenAICompatibleConfig::OpenAICompatibleConfig(
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
) -> OpenAICompatibleConfig {
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
pub fn OpenAICompatibleConfig::with_reasoning_effort(
  self : OpenAICompatibleConfig,
  effort : String,
) -> OpenAICompatibleConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, thinking: false, reasoning_effort: None }
  }
  if effort == "on" {
    if !self.thinking_efforts.is_empty() {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai_compatible",
        detail="unsupported reasoning effort: on (this endpoint declares explicit levels)",
      )
    }
    return { ..self, thinking: true, reasoning_effort: None }
  }
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_openai_compatible",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, thinking: true, reasoning_effort: Some(effort) }
}
