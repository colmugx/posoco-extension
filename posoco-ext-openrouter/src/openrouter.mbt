///|
/// posoco_ext_openrouter — ModelPort implementation.
///
/// Implements @posoco.ModelPort for the OpenRouter /api/v1/chat/completions
/// endpoint (ApiKey auth only). The distinguishing feature is the
/// `include_reasoning` switch: responses carry `reasoning_details`, which the
/// adapter stores verbatim on `Reasoning.raw` and replays on later turns.

///|
/// Build HTTP headers for OpenRouter API requests: ApiKey bearer plus the
/// optional `HTTP-Referer` / `X-Title` attribution headers (rankings only,
/// never inference behavior).
fn build_headers(config : OpenRouterConfig) -> @http.Headers {
  let headers : @http.Headers = {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
  match config.http_referer {
    Some(referer) =>
      headers[@http.CaseInsensitiveString("HTTP-Referer")] = referer
    None => ()
  }
  match config.title {
    Some(title) => headers[@http.CaseInsensitiveString("X-Title")] = title
    None => ()
  }
  headers
}

///|
/// The full chat completions URL: base_url + /chat/completions.
fn chat_url(config : OpenRouterConfig) -> String {
  config.base_url + "/chat/completions"
}

///|
/// The OpenRouter ModelPort implementation. Implements @posoco.ModelPort for
/// chat/chat_streaming (chat_native_js.mbt) and a summarize-based compact
/// (compact_native_js.mbt); wasm keeps raising fallbacks in the
/// *_wasm_fallback.mbt files.
pub(all) struct OpenRouterModelPort {
  config : OpenRouterConfig
}

///|
pub fn OpenRouterModelPort::OpenRouterModelPort(
  config : OpenRouterConfig,
) -> OpenRouterModelPort {
  { config, }
}

///|
/// ModelPort implementation — provider_config. Reasoning vocabulary stays
/// undeclared (the router learns levels from the slot, not from here); the
/// auto-compact metadata from settings IS reported so the Agent can build its
/// per-turn RunPolicy from the active model's own numbers.
pub impl @posoco.ModelPort for OpenRouterModelPort with fn provider_config(
  self : OpenRouterModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=self.config.compact_threshold,
  )
}
