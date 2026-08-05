///|
/// Configuration for OpenAICompatibleModelPort.
///
/// `base_url` and `model` are required — this adapter exists to reach custom
/// endpoints, so it deliberately has no vendor default. `endpoint_prefix` is
/// optional because most `/v1` servers already bake the version into base_url;
/// pass `/v1` only when base_url is a bare host. `reasoning_effort` is optional
/// and, when non-empty, is sent as a top-level request field per the OpenAI
/// convention adopted by Qwen3 / DeepSeek / Together / OpenRouter.
pub(all) struct OpenAICompatibleConfig {
  /// API key sent as `Authorization: Bearer <api_key>`.
  api_key : String
  /// Base URL, e.g. "https://dashscope.aliyuncs.com/compatible-mode/v1".
  base_url : String
  /// Endpoint path prefix, e.g. "/v1" when base_url is "http://host:port".
  endpoint_prefix : String
  /// Model id used for chat.
  model : String
  /// Optional reasoning effort sent as a top-level `reasoning_effort` field.
  /// Empty string means "omit the field". The adapter never wraps a `thinking`
  /// object; servers that ignore the field simply drop it.
  reasoning_effort : String
  /// Effort values the endpoint declares as selectable (from the settings
  /// `reasoning_efforts` array). Empty means the slot exposes no effort
  /// selector. The picker-facing slot additionally prepends the implicit
  /// "off" entry; it is never stored here.
  thinking_efforts : Array[String]
} derive(Eq, Debug)

///|
/// Config builder. `api_key`, `base_url`, and `model` are required.
pub fn OpenAICompatibleConfig::new(
  api_key : String,
  base_url~ : String,
  model~ : String,
  endpoint_prefix? : String = "",
  reasoning_effort? : String = "",
  thinking_efforts? : Array[String] = [],
) -> OpenAICompatibleConfig {
  {
    api_key,
    base_url,
    model,
    endpoint_prefix,
    reasoning_effort,
    thinking_efforts,
  }
}

///|
/// Rebuild a provider config with a validated effort value. The picker-facing
/// "off" entry maps to "" (omit the wire field); any other value must be one
/// of the declared `thinking_efforts`.
pub fn OpenAICompatibleConfig::with_reasoning_effort(
  self : OpenAICompatibleConfig,
  effort : String,
) -> OpenAICompatibleConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, reasoning_effort: "" }
  }
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_openai_compatible",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, reasoning_effort: effort }
}
