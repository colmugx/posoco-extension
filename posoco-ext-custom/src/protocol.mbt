///|
/// protocol.mbt — the three wire dialects a custom provider can be declared on.
///
/// A custom provider is one endpoint defined by user settings; the endpoint's
/// wire is configuration, not a property of this extension. The vocabulary is
/// shared with `posoco-ext-opencode-zen` (`WireKind::to_id`) so a gateway
/// served through either extension spells its protocol the same way.
///
/// Unknown ids resolve to `None` and the caller raises a typed composition
/// error: a misspelled `protocol` must never silently fall back to Chat
/// Completions, because the fallback would send a valid-looking request to the
/// wrong endpoint shape and surface as a confusing 400.

///|
/// The wire structure this provider's models are served on.
pub(all) enum CustomProtocol {
  /// `POST {base_url}{endpoint_prefix}/chat/completions` (default).
  ChatCompletions
  /// `POST {base_url}{endpoint_prefix}/responses` (OpenAI Responses API).
  Responses
  /// `POST {base_url}{endpoint_prefix}/messages` (Anthropic Messages API).
  Messages
} derive(Eq, Debug)

///|
pub extend CustomProtocol with Eq::{not_equal, equal}

///|
pub extend CustomProtocol with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Stable id used in settings and in every raised message.
pub fn CustomProtocol::to_id(self : CustomProtocol) -> String {
  match self {
    ChatCompletions => "chat_completions"
    Responses => "responses"
    Messages => "messages"
  }
}

///|
/// Inverse of `to_id`. `None` = not a protocol id; the caller decides whether
/// that is a composition failure (settings) or a skip (cache records).
pub fn custom_protocol_of_id(id : String) -> CustomProtocol? {
  match id {
    "chat_completions" => Some(ChatCompletions)
    "responses" => Some(Responses)
    "messages" => Some(Messages)
    _ => None
  }
}

///|
/// The accepted `protocol` values, worded for an error message.
pub fn custom_protocol_choices() -> String {
  "chat_completions, responses, messages"
}
