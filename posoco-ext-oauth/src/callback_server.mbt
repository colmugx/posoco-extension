///|
/// callback_server.mbt — PKCE browser flow with target-adaptive callback server.
///
/// Pattern mirrors posoco-ext-read: a priv trait (CallbackServer) defines the
/// IO seam; shared logic talks only to the trait; each target provides its own
/// impl via .native.mbt / .js.mbt files.
///
/// Native: @http.Server (moonbitlang/async)
/// JS:     Bun.serve (extern "js")

///|
/// Local HTTP callback server for PKCE browser flow.
/// Each target provides an impl:
///   - native: @http.Server
///   - js: Bun.serve via extern "js"
pub(open) trait CallbackServer {
  /// Start listening on localhost:port. The server captures the
  /// `code` query param from the OAuth redirect URL.
  async fn start(self : Self, port : Int) -> Unit raise OAuthError

  /// Block until the callback arrives. Returns the authorization code.
  /// Raises ExpiredToken on timeout (default 5 minutes).
  async fn wait_code(self : Self) -> String raise OAuthError

  /// Shut down the server and release the port.
  fn stop(self : Self) -> Unit
}

///|
/// Configuration for the PKCE authorization-code browser flow.
pub(all) struct PkceFlowConfig {
  client_id : String
  authorize_url : String // e.g. "https://auth.openai.com/oauth/authorize"
  token_url : String // e.g. "https://auth.openai.com/oauth/token"
  redirect_uri : String // e.g. "http://localhost:1455/auth/callback"
  callback_port : Int // e.g. 1455
  scope : String // e.g. "openid profile email offline_access"
}

///|
/// Run the full PKCE browser flow:
/// 1. Generate PKCE pair (verifier + challenge)
/// 2. Construct authorize URL with challenge in query
/// 3. Start callback server on localhost:callback_port
/// 4. Notify host to open the URL (AuthInteraction::notify)
/// 5. Wait for browser redirect → extract authorization code
/// 6. Exchange code + verifier for tokens (HTTP POST to token_url)
/// 7. Stop server, return Credential
///
/// The `server` parameter is a target-specific CallbackServer impl.
/// The `transport` parameter is an OAuthHttpTransport impl
/// (DefaultOAuthHttpTransport on native/js, host-supplied on wasm). Both are
/// target seams so this shared flow stays free of platform HTTP APIs.
pub async fn run_pkce_browser_flow(
  config : PkceFlowConfig,
  interaction : &AuthInteraction,
  server : &CallbackServer,
  transport : &OAuthHttpTransport,
) -> Credential raise OAuthError {
  let pkce = generate_pkce()

  let auth_url = build_authorize_url(config, pkce)

  server.start(config.callback_port)

  interaction.notify(AuthMessage::AuthUrl(auth_url))

  let code = server.wait_code()

  let cred = exchange_code_for_token(
    config,
    code,
    pkce.code_verifier,
    transport,
  )

  server.stop()

  cred
}

///|
/// Build the authorization URL with PKCE challenge.
fn build_authorize_url(config : PkceFlowConfig, pkce : PkcePair) -> String {
  let params = "response_type=code" +
    "&client_id=" +
    config.client_id +
    "&redirect_uri=" +
    url_encode(config.redirect_uri) +
    "&scope=" +
    url_encode(config.scope) +
    "&code_challenge=" +
    pkce.code_challenge +
    "&code_challenge_method=S256"
  config.authorize_url + "?" + params
}

///|
/// Exchange authorization code for tokens via the supplied transport. Core
/// OAuth logic (body shape, error mapping, response parsing) stays here; the
/// actual HTTP POST is delegated so this file never imports a platform HTTP
/// package.
async fn exchange_code_for_token(
  config : PkceFlowConfig,
  code : String,
  code_verifier : String,
  transport : &OAuthHttpTransport,
) -> Credential raise OAuthError {
  let headers : Map[String, String] = Map([
    ("Content-Type", "application/x-www-form-urlencoded"),
  ])
  let body = "grant_type=authorization_code" +
    "&client_id=" +
    config.client_id +
    "&code=" +
    url_encode(code) +
    "&code_verifier=" +
    url_encode(code_verifier) +
    "&redirect_uri=" +
    url_encode(config.redirect_uri)
  let response = transport.post(OAuthHttpRequest::{
    url: config.token_url,
    body,
    headers,
  })
  let resp_json = @json.parse(response.body) catch {
    err => raise OAuthError::ParseError("token response: " + err.to_string())
  }
  parse_token_response(resp_json)
}

///|
/// Parse an OAuth token response into a Credential.
fn parse_token_response(json : Json) -> Credential raise OAuthError {
  match json {
    Json::Object(map) => {
      match map.get("error") {
        Some(Json::String(err_code)) =>
          match err_code {
            "invalid_grant" => raise OAuthError::InvalidGrant
            other => raise OAuthError::HttpError("token error: " + other)
          }
        _ => ()
      }
      let access_token = match map.get("access_token") {
        Some(Json::String(s)) => s
        _ => raise OAuthError::ParseError("missing access_token")
      }
      let refresh_token = match map.get("refresh_token") {
        Some(Json::String(s)) => s
        _ => ""
      }
      let expires_in = match map.get("expires_in") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => 3600
      }
      let token_type = match map.get("token_type") {
        Some(Json::String(s)) => s
        _ => "Bearer"
      }
      let now_secs = (@async.now() / 1000L).to_int()
      Credential::Credential(
        access_token~,
        refresh_token~,
        expires_at=now_secs + expires_in,
        token_type~,
      )
    }
    _ => raise OAuthError::ParseError("token response not an object")
  }
}

///|
/// Minimal URL-encode for OAuth query params (encode spaces, &, =, etc).
fn url_encode(s : String) -> String {
  let buf = StringBuilder()
  for ch in s {
    if (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '-' ||
      ch == '.' ||
      ch == '_' ||
      ch == '~' {
      buf.write_char(ch)
    } else {
      let code = ch.to_int()
      buf.write_char('%')
      buf.write_string(int_to_hex_upper(code / 16))
      buf.write_string(int_to_hex_upper(code % 16))
    }
  }
  buf.to_string()
}

///|
fn int_to_hex_upper(n : Int) -> String {
  if n < 10 {
    n.to_string()
  } else {
    let ch = (n + 55).unsafe_to_char()
    ch.to_string()
  }
}
