///|
/// custom.mbt — the custom-provider ModelPort, credential placement, and the
/// self-description the router reads.
///
/// One port is scoped to one provider id and one model: the wire it speaks and
/// the way its credential rides are configuration, so a single port type serves
/// all three dialects. The `ModelPort::chat`/`compact` bodies live in
/// `port_native_js.mbt` because they open HTTP connections.

///|
/// The custom-provider ModelPort. Implements `@posoco.ModelPort` for the
/// declared protocol (chat completions, responses, or messages) and a
/// summarize-based compact that runs through the same wire.
pub(all) struct CustomModelPort {
  /// Provider id this port is scoped to (e.g. "my-gateway"). Used only for
  /// catalog labeling; it never appears on the wire request.
  provider_id : String
  config : CustomConfig
  /// Optional provider-owned hook evaluated immediately before every HTTP
  /// request. Entries override the wire defaults, so a host can add routing
  /// or identity headers without the extension learning their names.
  request_headers : (() -> Map[String, String])?
  /// Compatibility mirror retained for callers/tests that inspect the port.
  mut prompt_cache_key_rejected : Bool
  /// Shared process-local compatibility state threaded through this provider's
  /// catalog and every slot rebuild.
  prompt_cache_key_rejection_state : Ref[Bool]
}

///|
pub fn CustomModelPort::CustomModelPort(
  provider_id : String,
  config : CustomConfig,
  request_headers? : () -> Map[String, String],
) -> CustomModelPort {
  {
    provider_id,
    config,
    request_headers,
    prompt_cache_key_rejected: false,
    prompt_cache_key_rejection_state: Ref(false),
  }
}

///|
/// Build one port that shares the provider's compatibility state, so an
/// endpoint that rejected `prompt_cache_key` once is not asked again by any
/// slot rebuilt from the same provider instance.
fn custom_model_port_with_prompt_cache_rejection_state(
  provider_id : String,
  config : CustomConfig,
  state : Ref[Bool],
  request_headers? : () -> Map[String, String],
) -> CustomModelPort {
  {
    provider_id,
    config,
    request_headers,
    prompt_cache_key_rejected: state.val,
    prompt_cache_key_rejection_state: state,
  }
}

///|
fn CustomModelPort::prompt_cache_key_rejected_now(
  self : CustomModelPort,
) -> Bool {
  if self.prompt_cache_key_rejected {
    self.prompt_cache_key_rejection_state.val = true
  }
  self.prompt_cache_key_rejection_state.val
}

///|
/// 400-learning entry point: run the kit rejection matcher over one non-2xx
/// error body and remember an explicit `prompt_cache_key` rejection for every
/// later port rebuilt from the same custom provider instance.
fn CustomModelPort::learn_prompt_cache_key_rejection(
  self : CustomModelPort,
  error_body_text : String,
) -> Unit {
  if @chatkit.is_prompt_cache_key_rejection(error_body_text) {
    self.prompt_cache_key_rejected = true
    self.prompt_cache_key_rejection_state.val = true
  }
}

///|
/// Resolve the request's `prompt_cache_key`: derived from the session id via
/// the shared kit helper, only when the endpoint opted in and the provider has
/// not already rejected the parameter.
fn custom_resolve_cache_key(
  send_prompt_cache_key : Bool,
  rejected : Bool,
  session_id : String,
) -> String? {
  if send_prompt_cache_key && !rejected {
    Some(@chatkit.derive_prompt_cache_key(session_id))
  } else {
    None
  }
}

///|
/// Wire headers for the port's protocol. `auth` decides where the credential
/// rides; the Messages wire additionally states its required
/// `anthropic-version`, since that dialect refuses requests without it.
fn build_wire_headers(
  config : CustomConfig,
  request_headers : (() -> Map[String, String])?,
) -> @http.Headers {
  let key = config.api_key
  let headers : @http.Headers = match (config.protocol, config.auth) {
    (Messages, Bearer) =>
      {
        "Authorization": "Bearer \{key}",
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
      }
    (Messages, _) =>
      {
        "x-api-key": key,
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
      }
    (_, ApiKeyHeader) =>
      { "x-api-key": key, "Content-Type": "application/json" }
    (_, _) =>
      { "Authorization": "Bearer \{key}", "Content-Type": "application/json" }
  }
  match request_headers {
    Some(supply) =>
      for header, value in supply() {
        headers[@http.CaseInsensitiveString(header)] = value
      }
    None => ()
  }
  headers
}

///|
/// Reasoning vocabulary stays undeclared (the router learns levels from the
/// slot, not from here); the auto-compact metadata from `models[]` settings IS
/// reported so the Agent can build its per-turn RunPolicy from the active
/// model's own numbers.
pub impl @posoco.ModelPort for CustomModelPort with fn provider_config(
  self : CustomModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=self.config.compact_threshold,
  )
}

///|
pub extend CustomModelPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}
