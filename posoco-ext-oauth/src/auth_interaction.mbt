///|
/// auth_interaction.mbt — UI abstraction for OAuth user interaction.
///
/// OAuth flows need to communicate with the user: show a URL to open, display
/// a device code, report progress, or prompt for manual input. Hosts inject
/// an AuthInteraction impl that bridges to their UI (TUI, web, headless).

///|
/// Message types sent to the host during OAuth.
pub(all) enum AuthMessage {
  AuthUrl(String) // open this URL in a browser
  DeviceCode(String, String) // (verification_uri, user_code) — display both
  Progress(String) // human-readable status update
}

///|
pub(open) trait AuthInteraction {
  /// Notify the user of a step (show URL, display code, etc.). Never blocks.
  fn notify(Self, message : AuthMessage) -> Unit

  /// Check if the user wants to cancel. Called between poll iterations.
  /// Hosts return true to abort the flow.
  fn is_cancelled(Self) -> Bool
}

///|
/// A no-op AuthInteraction for headless/CI use. All notifications are
/// discarded and cancellation is never signalled.
pub(all) struct NoopAuthInteraction {}

///|
pub fn NoopAuthInteraction::NoopAuthInteraction() -> NoopAuthInteraction {
  NoopAuthInteraction::{ }
}

///|
pub impl AuthInteraction for NoopAuthInteraction with fn notify(
  _self : NoopAuthInteraction,
  _message : AuthMessage,
) {
  ()
}

///|
pub impl AuthInteraction for NoopAuthInteraction with fn is_cancelled(
  _self : NoopAuthInteraction,
) -> Bool {
  false
}

///|
/// Provider-neutral prompt options used by non-OAuth authentication flows.
/// The host renders these without knowing which provider requested them.
pub(all) struct AuthPromptOption {
  id : String
  label : String
  description : String?
}

///|
pub fn AuthPromptOption::AuthPromptOption(
  id~ : String,
  label~ : String,
  description? : String? = None,
) -> AuthPromptOption {
  { id, label, description, }
}

///|
/// A provider-neutral interactive authentication request. Secret values must
/// never be echoed by hosts or included in diagnostics.
pub(all) enum AuthPromptRequest {
  Secret(message~ : String)
  Select(message~ : String, options~ : Array[AuthPromptOption])
}

///|
/// Optional prompt seam for provider-owned API-key login. It is deliberately
/// separate from `AuthInteraction` so existing OAuth-only hosts remain source
/// compatible; a host that advertises API-key login implements both traits.
pub(open) trait AuthPromptInteraction {
  /// Prompt for a secret or select option. Cancellation and UI failures are
  /// typed OAuth errors so provider login cannot silently continue.
  async fn prompt(Self, request : AuthPromptRequest) -> String raise OAuthError
}

///|
/// Headless prompt implementation for tests. It fails loudly because an
/// unattended host must not pretend it obtained an API key.
pub(all) struct NoopAuthPromptInteraction {}

///|
pub fn NoopAuthPromptInteraction::NoopAuthPromptInteraction() -> NoopAuthPromptInteraction {
  NoopAuthPromptInteraction::{ }
}

///|
pub impl AuthPromptInteraction for NoopAuthPromptInteraction with fn prompt(
  _self : NoopAuthPromptInteraction,
  _request : AuthPromptRequest,
) -> String raise OAuthError {
  raise OAuthError::Cancelled
}
