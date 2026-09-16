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
fn chat_url(config : OpenRouterConfig) -> String {
  config.base_url + "/chat/completions"
}

///|
pub(all) struct OpenRouterModelPort {
  config : OpenRouterConfig
  /// Compatibility mirror retained for callers/tests that inspect the port.
  mut prompt_cache_key_rejected : Bool
  /// Shared process-local compatibility state threaded through catalog,
  /// credential, effort, and discovery rebuilds.
  prompt_cache_key_rejection_state : Ref[Bool]
}

///|
pub fn OpenRouterModelPort::OpenRouterModelPort(
  config : OpenRouterConfig,
) -> OpenRouterModelPort {
  {
    config,
    prompt_cache_key_rejected: false,
    prompt_cache_key_rejection_state: Ref(false),
  }
}

///|
fn openrouter_model_port_with_prompt_cache_rejection_state(
  config : OpenRouterConfig,
  state : Ref[Bool],
) -> OpenRouterModelPort {
  {
    config,
    prompt_cache_key_rejected: state.val,
    prompt_cache_key_rejection_state: state,
  }
}

///|
/// The session-scoped `prompt_cache_key` for an invocation, or None when the
/// feature is opted out (`config.send_prompt_cache_key`) or the provider
/// rejected the parameter earlier in this process.
fn OpenRouterModelPort::prompt_cache_key(
  self : OpenRouterModelPort,
  scope : @posoco.InvocationScope,
) -> String? {
  if self.prompt_cache_key_rejected {
    self.prompt_cache_key_rejection_state.val = true
  }
  if !self.config.send_prompt_cache_key || self.prompt_cache_key_rejection_state.val {
    return None
  }
  Some(@chatkit.derive_prompt_cache_key(scope.session_id.to_string()))
}

///|
/// Learn from a drained non-2xx body: an explicit "unsupported parameter"
/// rejection naming `prompt_cache_key` stops sending the key for every later
/// port that shares this provider lifecycle state. Unreadable or unrelated
/// bodies never set the flag.
fn OpenRouterModelPort::learn_cache_key_rejection(
  self : OpenRouterModelPort,
  body : OpenRouterErrorBody,
) -> Unit {
  if openrouter_body_rejects_cache_key(body) {
    self.prompt_cache_key_rejected = true
    self.prompt_cache_key_rejection_state.val = true
  }
}

///|
/// Reasoning vocabulary stays undeclared (the router learns levels from the
/// slot, not from here); the auto-compact metadata from settings IS reported
/// so the Agent can build its per-turn RunPolicy from the active model's own
/// numbers.
pub impl @posoco.ModelPort for OpenRouterModelPort with fn provider_config(
  self : OpenRouterModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=self.config.compact_threshold,
  )
}
