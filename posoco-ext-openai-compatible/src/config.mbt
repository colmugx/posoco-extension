///|
/// Configuration for OpenAICompatibleModelPort.
///
/// `base_url` and `model` are required — this adapter exists to reach custom
/// endpoints, so it deliberately has no vendor default. `endpoint_prefix` is
/// optional because most `/v1` servers already bake the version into base_url;
/// pass `/v1` only when base_url is a bare host.
pub(all) struct OpenAICompatibleConfig {
  /// API key sent as `Authorization: Bearer <api_key>`.
  api_key : String
  /// Base URL, e.g. "https://dashscope.aliyuncs.com/compatible-mode/v1".
  base_url : String
  /// Endpoint path prefix, e.g. "/v1" when base_url is "http://host:port".
  endpoint_prefix : String
  /// Model id used for chat.
  model : String
  /// Selected effort level; None omits the field (endpoint default).
  reasoning_effort : String?
  /// Declared selectable effort levels. The slot prepends the implicit
  /// "off" entry for the picker; it is never stored here.
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
  /// Opts in to sending a provider-side `prompt_cache_key` derived from the
  /// session id, so cache-aware providers can pin the session to a cache
  /// shard. Off by default: unknown gateways may reject the parameter; an
  /// explicit rejection is then learned per process and the key is omitted
  /// from subsequent requests.
  send_prompt_cache_key : Bool
} derive(Eq, Debug)

///|
/// Config builder. `api_key`, `base_url`, and `model` are required.
pub fn OpenAICompatibleConfig::OpenAICompatibleConfig(
  api_key : String,
  base_url~ : String,
  model~ : String,
  endpoint_prefix? : String = "",
  reasoning_effort? : String? = None,
  thinking_efforts? : Array[String] = [],
  context_window? : Int? = None,
  compact_threshold? : Double? = None,
  supports_images? : Bool = false,
  send_prompt_cache_key? : Bool = false,
) -> OpenAICompatibleConfig {
  {
    api_key,
    base_url,
    model,
    endpoint_prefix,
    reasoning_effort,
    thinking_efforts,
    context_window,
    compact_threshold,
    supports_images,
    send_prompt_cache_key,
  }
}

///|
/// Rebuild a provider config with a validated selector value.
///
/// "off" and "on" both select omission ("on" is a legacy alias so stored
/// settings keep composing) and "on" is rejected while explicit levels are
/// declared; any other value must be one of the declared `thinking_efforts`
/// and sends that level verbatim.
pub fn OpenAICompatibleConfig::with_reasoning_effort(
  self : OpenAICompatibleConfig,
  effort : String,
) -> OpenAICompatibleConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, reasoning_effort: None, }
  }
  if effort == "on" {
    if !self.thinking_efforts.is_empty() {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai_compatible",
        detail="unsupported reasoning effort: on (this endpoint declares explicit levels)",
      )
    }
    return { ..self, reasoning_effort: None, }
  }
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_openai_compatible",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, reasoning_effort: Some(effort), }
}
