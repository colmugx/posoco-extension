///|
/// oauth_provider.mbt — the core OAuth provider trait.
///
/// Each provider (Kimi, OpenAI/Codex, etc.) implements this trait to
/// encapsulate its OAuth flow. ext-oauth provides the shared device-flow
/// polling and PKCE helpers; providers supply endpoints and client config.

///|
/// A provider that can obtain and refresh OAuth credentials.
///
/// Lifecycle:
///   1. `login(interaction)` — run the OAuth flow (device or PKCE),
///      returning a fresh Credential.
///   2. `refresh(credential)` — exchange a refresh_token for new tokens.
///   3. `to_auth(credential)` — convert a Credential to HTTP auth headers.
pub(open) trait OAuthProvider {
  /// Stable identifier for credential storage (e.g. "kimi", "openai-codex").
  fn provider_id(Self) -> String

  /// Run the full OAuth login flow. Uses `interaction` for user-facing steps
  /// (show URL, display device code). Returns a Credential on success.
  async fn login(Self, interaction : &AuthInteraction) -> Credential raise OAuthError

  /// Refresh an expired access token using its refresh_token.
  /// Raises InvalidGrant if the refresh_token itself is expired/revoked.
  async fn refresh(Self, credential : Credential) -> Credential raise OAuthError

  /// Convert a Credential to auth headers for HTTP requests.
  fn to_auth(Self, credential : Credential) -> AuthHeader
}
