///|
/// Zen's upstream speaks a GLM-flavored OpenAI Chat Completions dialect on
/// the chat-completions plane: `thinking: {"type": "enabled"}`, top-level
/// `reasoning_effort`, and `reasoning_content` echoed on assistant messages.
/// Models served on the other planes use their vendor-native structure
/// (Anthropic Messages, OpenAI Responses) — see protocol.mbt.

///|
/// Whether a chat-completions model speaks the GLM-flavored dialect. Only
/// the GLM upstreams take the `thinking` object; other chat-completions
/// models (kimi, deepseek, minimax, ...) get the standard OpenAI shape.

///|
/// Configuration for OpenCodeZenModelPort. `endpoint_prefix` stays empty
/// for Zen because its base URL already carries `/v1`.
pub(all) struct OpenCodeZenConfig {
  /// API key sent as `Authorization: Bearer <api_key>` on the OpenAI planes;
  /// the Anthropic Messages plane sends it as `x-api-key`.
  api_key : String
  /// Base URL, conventionally "https://opencode.ai/inference/v1".
  base_url : String
  /// Endpoint path prefix; empty for Zen (the base URL carries `/v1`).
  endpoint_prefix : String
  /// Model id used for chat.
  model : String
  /// Thinking toggle; false omits fields on generic wires, while the
  /// DeepSeek Chat Completions dialect explicitly sends thinking=disabled.
  thinking : Bool
  /// Selected effort level, sent verbatim while thinking is enabled.
  reasoning_effort : String?
  /// Selectable effort levels (efforts.mbt preset table); empty = off/on only.
  thinking_efforts : Array[String]
  /// Declared context capacity of `model`, in tokens. `None` = undeclared;
  /// auto-compact stays off for this model rather than guessing a window.
  context_window : Int32?
  /// Declared auto-compact trigger point as a fraction of the context window,
  /// in (0, 1]. `None` = the host/core default applies.
  compact_threshold : Double?
  /// Declares that `model` accepts image input. When true, messages carrying
  /// Image blocks encode as typed content parts; when false, images downgrade
  /// to an explicit placeholder instead of being sent or silently dropped.
  supports_images : Bool
  /// The wire structure this model is served on (see protocol.mbt). The
  /// default keeps the historical Chat Completions shape.
  wire : WireKind
  /// Output-token ceiling for wires that require one (Anthropic Messages
  /// `max_tokens`). Settings can override per provider.
  max_output_tokens : Int32
  /// Declared per-1M-token rates for the spend estimate; `None` = no price
  /// known, the estimate stays silent.
  rates : ZenCostRates?
  /// Product identity carried in the routing headers and User-Agent
  /// ("opencode-zen", "opencode-go", ...).
  client_id : String
  /// The status source this port records its spend estimate under.
  spend_source : String
} derive(Eq, Debug)

///|
pub extend OpenCodeZenConfig with Eq::{not_equal, equal}

///|
pub extend OpenCodeZenConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Config builder. `api_key`, `base_url`, and `model` are required.
pub fn OpenCodeZenConfig::OpenCodeZenConfig(
  api_key : String,
  base_url~ : String,
  model~ : String,
  endpoint_prefix~ : String = "",
  thinking~ : Bool = false,
  reasoning_effort~ : String? = None,
  thinking_efforts~ : Array[String] = [],
  context_window~ : Int32? = None,
  compact_threshold~ : Double? = None,
  supports_images~ : Bool = false,
  wire~ : WireKind = ChatCompletions,
  max_output_tokens~ : Int32 = 32768,
  rates~ : ZenCostRates? = None,
  client_id~ : String = "opencode-zen",
  spend_source~ : String = "posoco_ext_opencode_zen",
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
    wire,
    max_output_tokens,
    rates,
    client_id,
    spend_source,
  }
}

///|
/// Rebuild a provider config with a validated selector value.
///
/// The picker-facing vocabulary: "off" disables thinking (no effort field);
/// "on" enables thinking without an effort level and exists only while no
/// levels are declared; any other value must be one of the declared
/// `thinking_efforts` and enables thinking with that level sent verbatim.
/// How the stored (thinking, effort) pair maps onto wire fields is decided
/// by each wire's encoder — including `none`, which the Messages and
/// Responses encoders treat as a disable. `on` on a wire without levels
/// means "enable thinking, default budget".
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
fn build_headers(
  config : OpenCodeZenConfig,
  scope : @posoco.InvocationScope,
) -> @http.Headers {
  let headers : @http.Headers = {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
  for
    key, value in opencode_request_headers(
      config.client_id,
      scope.session_id.to_string(),
    ) {
    headers[@http.CaseInsensitiveString(key)] = value
  }
  headers
}

///|
/// Anthropic-plane auth: the gateway's Messages endpoint takes the key as
/// `x-api-key` with an explicit `anthropic-version`, plus the same routing
/// metadata as the OpenAI planes.
fn build_messages_headers(
  config : OpenCodeZenConfig,
  scope : @posoco.InvocationScope,
) -> @http.Headers {
  let headers : @http.Headers = {
    "x-api-key": config.api_key,
    "Content-Type": "application/json",
    "anthropic-version": "2023-06-01",
  }
  for
    key, value in opencode_request_headers(
      config.client_id,
      scope.session_id.to_string(),
    ) {
    headers[@http.CaseInsensitiveString(key)] = value
  }
  headers
}

///|
/// Map a models.dev effort level to an Anthropic thinking budget (tokens).
/// The gateway normalizes reasoning controls per upstream, so the level
/// names are the picker's vocabulary, not Anthropic's; budgets are a fixed
/// ladder, floored at the 1024-token minimum the Messages API requires.
fn zen_messages_thinking_budget(level : String) -> Int32 {
  let budget = match level {
    "minimal" | "low" => 4096
    "medium" => 8192
    "high" => 16384
    "xhigh" => 24576
    "max" => 32768
    _ => 8192
  }
  if budget < 1024 {
    1024
  } else {
    budget
  }
}

///|
fn chat_url(config : OpenCodeZenConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
/// The Zen ModelPort implementation.
pub(all) struct OpenCodeZenModelPort {
  config : OpenCodeZenConfig
  inspector : ((@posoco.StreamAccumulator, Bool) -> StreamVerdict)?
}

///|
pub fn OpenCodeZenModelPort::OpenCodeZenModelPort(
  config : OpenCodeZenConfig,
) -> OpenCodeZenModelPort {
  { config, inspector: None, }
}

///|
pub fn OpenCodeZenModelPort::with_inspector(
  self : OpenCodeZenModelPort,
  inspector~ : ((@posoco.StreamAccumulator, Bool) -> StreamVerdict)?,
) -> OpenCodeZenModelPort {
  { ..self, inspector, }
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

///|
pub extend OpenCodeZenModelPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}
