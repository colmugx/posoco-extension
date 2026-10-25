///|
/// Per-model wire dispatch for the OpenCode gateway.
///
/// The gateway serves each model on the vendor-native structure of its
/// upstream (see the Console endpoints table and the OpenCode Go endpoints
/// table): OpenAI Chat Completions, OpenAI Responses, Anthropic Messages,
/// Google Generative AI, and the Jev SystemOne endpoint. `/models` carries no
/// protocol metadata, so the wire is derived, never stored as configuration:
/// settings override, then the in-code table distilled from the vendor
/// endpoints tables, then the models.dev `provider.npm` signal, then family
/// fallback by id prefix, then the gateway default (Chat Completions).
///
/// `GoogleGenai`, and the Mistral Conversations dialect have no posoco kit yet
/// (Google is planned for v2): models resolving to them are excluded from the
/// catalog with a typed reason instead of being offered on a wire that
/// answers `400 ModelProtocolUnsupported`. `SystemOne` is the structured
/// decision wire: those models are catalogued as `kind = Decision` slots
/// served by the provider-owned decision port, never as chat models.

///|
/// The wire structure a model is served on.
pub(all) enum WireKind {
  ChatCompletions
  Messages
  Responses
  GoogleGenai
  SystemOne
  MistralDialect
} derive(Eq, Debug)

///|
pub extend WireKind with Eq::{not_equal, equal}

///|
pub extend WireKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Stable id used in settings overrides and host-cached records.
pub fn WireKind::to_id(self : WireKind) -> String {
  match self {
    ChatCompletions => "chat_completions"
    Messages => "messages"
    Responses => "responses"
    GoogleGenai => "google_genai"
    SystemOne => "system_one"
    MistralDialect => "mistral"
  }
}

///|
/// Inverse of `to_id`; unknown ids resolve to `None` so a malformed override
/// or cache entry is visible to the caller instead of silently coerced.
pub fn wire_kind_of_id(id : String) -> WireKind? {
  match id {
    "chat_completions" => Some(ChatCompletions)
    "messages" => Some(Messages)
    "responses" => Some(Responses)
    "google_genai" => Some(GoogleGenai)
    "system_one" => Some(SystemOne)
    "mistral" => Some(MistralDialect)
    _ => None
  }
}

///|
/// Whether this extension can serve the wire as a *chat* wire. The two
/// unserved kinds are excluded from the conversation catalog; the reason is
/// `wire_exclusion_reason`. `SystemOne` is not a chat wire either — but it is
/// served as decision slots (`wire_is_decision`), so it is not "unserved".
pub fn wire_servable(kind : WireKind) -> Bool {
  match kind {
    ChatCompletions | Messages | Responses => true
    GoogleGenai | SystemOne | MistralDialect => false
  }
}

///|
/// Whether the wire is the structured decision endpoint. Models resolving
/// here are catalogued as `kind = Decision` slots (`/decision` candidates)
/// backed by the provider-owned decision port, and never as chat models.
pub fn wire_is_decision(kind : WireKind) -> Bool {
  kind is SystemOne
}

///|
/// Why a wire is not served, worded for the typed exclusion surfaced to the
/// user through the refresh/catalog diagnostics.
pub fn wire_exclusion_reason(kind : WireKind) -> String {
  match kind {
    GoogleGenai =>
      "google generative ai wire is not supported yet (planned for a later kit)"
    SystemOne => "systemone is a structured decision endpoint, not a chat wire"
    MistralDialect =>
      "mistral conversations dialect is not supported on the shared wires"
    _ => "supported"
  }
}

///|
/// The models.dev `provider.npm` signal distilled from the vendor catalog:
/// the SDK opencode itself ships per model names the wire. Absent and
/// `@ai-sdk/openai-compatible` mean the gateway default (Chat Completions).
pub fn wire_from_models_dev_npm(npm : String?) -> WireKind? {
  match npm {
    Some("@ai-sdk/openai") => Some(Responses)
    Some("@ai-sdk/anthropic") => Some(Messages)
    Some("@ai-sdk/google") => Some(GoogleGenai)
    Some("@ai-sdk/mistral") => Some(MistralDialect)
    Some("@ai-sdk/openai-compatible") => Some(ChatCompletions)
    Some(_) => None
    None => Some(ChatCompletions)
  }
}

///|
/// Id-family fallback for models the tables do not describe (the gateway
/// lists ids ahead of its docs). Family prefixes are the vendor's own
/// grouping; unmatched ids fall to the gateway default (Chat Completions)
/// at the caller.
pub fn wire_from_family(model_id : String) -> WireKind? {
  if model_id.has_prefix("claude-") {
    return Some(Messages)
  }
  if model_id.has_prefix("gpt-") ||
    model_id.has_prefix("grok-") ||
    model_id.has_prefix("muse-") {
    return Some(Responses)
  }
  if model_id.has_prefix("gemini-") {
    return Some(GoogleGenai)
  }
  if model_id.has_prefix("jev-") {
    return Some(SystemOne)
  }
  if model_id.has_prefix("qwen") {
    return Some(Messages)
  }
  None
}

///|
/// Per-product overrides where the family rule disagrees with the vendor
/// endpoints table. Zen serves `qwen3.8-max` on chat completions and every
/// other qwen on messages; `mistral-large-4` is documented on chat
/// completions despite its models.dev SDK.
let zen_wire_overrides : Map[String, WireKind] = Map::from_array([
  ("qwen3.8-max", ChatCompletions),
  ("mistral-large-4", ChatCompletions),
])

///|
/// Resolve one model's wire for the Zen (Console) gateway. Precedence:
/// settings override, in-code table, models.dev npm signal, family fallback,
/// gateway default (Chat Completions). An absent npm is treated as no signal
/// (family and default still apply); only an explicit
/// `@ai-sdk/openai-compatible` pins Chat Completions.
pub fn resolve_zen_wire(
  model_id : String,
  npm~ : String? = None,
  overrides~ : Map[String, String] = Map::from_array([]),
) -> WireKind {
  match overrides.get(model_id) {
    Some(id) =>
      match wire_kind_of_id(id) {
        Some(kind) => return kind
        None => ()
      }
    None => ()
  }
  match zen_wire_overrides.get(model_id) {
    Some(kind) => return kind
    None => ()
  }
  match npm {
    Some(value) =>
      match wire_from_models_dev_npm(Some(value)) {
        Some(kind) => return kind
        None => ()
      }
    None => ()
  }
  match wire_from_family(model_id) {
    Some(kind) => kind
    None => ChatCompletions
  }
}
