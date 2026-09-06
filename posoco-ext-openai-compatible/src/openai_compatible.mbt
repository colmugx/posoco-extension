///|
/// Build HTTP headers for OpenAI-compatible API requests. When
/// `request_headers` is supplied it is evaluated per request and its entries
/// override the defaults, so adapters can rotate identity headers.
fn build_headers(
  config : OpenAICompatibleConfig,
  request_headers : (() -> Map[String, String])?,
) -> @http.Headers {
  let headers : @http.Headers = {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
  match request_headers {
    Some(supply) =>
      for key, value in supply() {
        headers[@http.CaseInsensitiveString(key)] = value
      }
    None => ()
  }
  headers
}

///|
fn chat_url(config : OpenAICompatibleConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
/// The OpenAI-compatible ModelPort implementation. Implements @posoco.ModelPort
/// for chat/chat_streaming (chat_native_js.mbt) and a summarize-based compact
/// (compact_native_js.mbt); wasm keeps raising fallbacks in the
/// *_wasm_fallback.mbt files.
pub(all) struct OpenAICompatibleModelPort {
  config : OpenAICompatibleConfig
  /// Provider id this port is scoped to (e.g. "qwen"). Used only for catalog
  /// labeling; it never appears on the wire request.
  provider_id : String
  /// Optional provider-owned hook evaluated immediately before every HTTP
  /// request. This keeps gateway-specific routing/identity headers out of the
  /// generic OpenAI-compatible config while allowing adapters such as
  /// OpenCode Zen to provide fresh request metadata.
  request_headers : (() -> Map[String, String])?
  /// Per-process learning: set once the provider explicitly rejects the
  /// `prompt_cache_key` parameter in an error body; subsequent requests omit
  /// the key. Never persisted.
  mut prompt_cache_key_rejected : Bool
}

///|
pub fn OpenAICompatibleModelPort::OpenAICompatibleModelPort(
  provider_id : String,
  config : OpenAICompatibleConfig,
  request_headers? : () -> Map[String, String],
) -> OpenAICompatibleModelPort {
  { provider_id, config, request_headers, prompt_cache_key_rejected: false, }
}

///|
/// 400-learning entry point: run the kit rejection matcher over one non-2xx
/// error body and remember an explicit `prompt_cache_key` rejection for the
/// rest of this process.
fn OpenAICompatibleModelPort::learn_prompt_cache_key_rejection(
  self : OpenAICompatibleModelPort,
  error_body_text : String,
) -> Unit {
  if @chatkit.is_prompt_cache_key_rejection(error_body_text) {
    self.prompt_cache_key_rejected = true
  }
}

///|
/// Reasoning vocabulary stays undeclared (the router learns levels from the
/// slot, not from here); the auto-compact metadata from `models[]` settings
/// IS reported so the Agent can build its per-turn RunPolicy from the active
/// model's own numbers.
pub impl @posoco.ModelPort for OpenAICompatibleModelPort with fn provider_config(
  self : OpenAICompatibleModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=self.config.compact_threshold,
  )
}
