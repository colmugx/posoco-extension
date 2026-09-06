///|
/// Codex login via the shared PKCE browser flow.
///
/// OpenAI's device endpoint can 404, while the browser authorization-code
/// flow is the official CLI's primary path. Ports 1455 (fallback 1457) match
/// the official CLI's redirect allow-list
/// (http://localhost:1455/auth/callback).

///|
/// Browser login needs the local callback server, which only exists on the
/// native and js targets.
#cfg(any(target="native", target="js"))
async fn CodexOAuth::run_browser_login(
  self : CodexOAuth,
  interaction : &@oauth.AuthInteraction,
  server : &@oauth.CallbackServer,
) -> @oauth.Credential raise @oauth.OAuthError {
  let config : @oauth.PkceFlowConfig = {
    client_id: codex_client_id,
    authorize_url: codex_auth_base + "/oauth/authorize",
    token_url: codex_auth_base + "/oauth/token",
    redirect_uri: "http://localhost:1455/auth/callback",
    callback_port: 1455,
    scope: "openid profile email offline_access",
    extra_authorize_params: [
      ("originator", identity_originator),
      ("id_token_add_organizations", "true"),
      ("codex_cli_simplified_flow", "true"),
    ],
    fallback_port: Some(1457),
  }
  let transport : &@oauth.OAuthHttpTransport = match self.transport {
    Some(transport) => transport
    None => {
      let default_transport = @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport()
      let transport : &@oauth.OAuthHttpTransport = default_transport
      transport
    }
  }
  @oauth.run_pkce_browser_flow(
    config,
    interaction,
    server,
    transport,
    parse_credential=parse_token_response,
  )
}

///|
/// Browser login needs the local callback server, which only exists on the
/// native and js targets.
#cfg(any(target="native", target="js"))
pub impl @oauth.OAuthProvider for CodexOAuth with fn login(
  self : CodexOAuth,
  interaction : &@oauth.AuthInteraction,
) -> @oauth.Credential raise @oauth.OAuthError {
  let server_impl = @oauth.create_callback_server()
  let server : &@oauth.CallbackServer = server_impl
  self.run_browser_login(interaction, server)
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @oauth.OAuthProvider for CodexOAuth with fn login(
  _self : CodexOAuth,
  _interaction : &@oauth.AuthInteraction,
) -> @oauth.Credential raise @oauth.OAuthError {
  raise @oauth.OAuthError::HttpError(
    "codex browser login is not supported on this target",
  )
}
