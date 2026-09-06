///|
/// callback_server.mbt — PKCE browser flow with target-adaptive callback server.
///
/// A priv trait (CallbackServer) defines the
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
  /// Start listening on localhost:port.
  async fn start(self : Self, port : Int) -> Unit raise OAuthError

  /// Block until the callback arrives. Returns (code, state) from the OAuth
  /// redirect query. Raises ExpiredToken on timeout (default 5 minutes).
  async fn wait_callback(self : Self) -> (String, String) raise OAuthError

  /// Shut down the server and release the port. Safe to call more than once.
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
  /// Provider-specific authorize-URL params (e.g. Codex's originator /
  /// codex_cli_simplified_flow), appended url-encoded in array order.
  extra_authorize_params : Array[(String, String)]
  /// Port to retry the callback bind when callback_port is occupied. The
  /// redirect_uri port segment is rewritten to the port actually bound so the
  /// authorize URL and token exchange stay identical.
  fallback_port : Int?
}

///|
priv enum CallbackWinner {
  ServerWon(String, String)
  PasteWon(String, String)
}

///|
/// Run the full PKCE browser flow:
/// 1. Generate PKCE pair + random state
/// 2. Construct authorize URL with challenge + state (+ extras)
/// 3. Start callback server (retry on fallback_port when configured)
/// 4. Notify host to open the URL (AuthInteraction::notify)
/// 5. Wait for the callback (code, state); with `prompt`, race a manual
///    paste prompt against the server
/// 6. Validate state, exchange code + verifier for tokens
/// 7. Stop the server on success AND on every raise path after start
///
/// The `server` parameter is a target-specific CallbackServer impl.
/// The `transport` parameter is an OAuthHttpTransport impl
/// (DefaultOAuthHttpTransport on native/js, host-supplied on wasm). Both are
/// target seams so this shared flow stays free of platform HTTP APIs.
/// `parse_credential` defaults to the lenient `parse_token_response` below.
pub async fn run_pkce_browser_flow(
  config : PkceFlowConfig,
  interaction : &AuthInteraction,
  server : &CallbackServer,
  transport : &OAuthHttpTransport,
  parse_credential? : (Json) -> Credential raise OAuthError,
  prompt? : &AuthPromptInteraction,
) -> Credential raise OAuthError {
  let pkce = generate_pkce()
  let state = generate_state()
  let actual_port = start_callback_server(config, server)
  // OAuth requires an identical redirect_uri in authorize and exchange.
  let redirect_uri = rewrite_redirect_port(
    config.redirect_uri,
    config.callback_port,
    actual_port,
  )
  let auth_url = build_authorize_url(config, pkce, state, redirect_uri)
  interaction.notify(AuthMessage::AuthUrl(auth_url))
  let winner = receive_callback(auth_url, server, prompt)
  // Every path after start must release the port.
  server.stop()
  let (code, received_state) = match winner {
    ServerWon(code, received) => (code, received)
    PasteWon(code, received) => (code, received)
  }
  if received_state != state {
    raise OAuthError::ParseError("oauth state mismatch")
  }
  exchange_code_for_token(
    config,
    code,
    pkce.code_verifier,
    redirect_uri,
    transport,
    parse_credential,
  )
}

///|
/// Start on callback_port; when that bind fails and fallback_port differs,
/// retry there. Returns the port actually bound.
async fn start_callback_server(
  config : PkceFlowConfig,
  server : &CallbackServer,
) -> Int raise OAuthError {
  let primary = Ok(server.start(config.callback_port)) catch { err => Err(err) }
  match primary {
    Ok(_) => config.callback_port
    Err(primary_error) =>
      match config.fallback_port {
        Some(fallback) =>
          if fallback != config.callback_port {
            let retried = Ok(server.start(fallback)) catch { err => Err(err) }
            match retried {
              Ok(_) => fallback
              Err(_) => raise primary_error
            }
          } else {
            raise primary_error
          }
        None => raise primary_error
      }
  }
}

///|
/// Swap the port segment of redirect_uri when the fallback port won.
fn rewrite_redirect_port(
  redirect_uri : String,
  from_port : Int,
  to_port : Int,
) -> String {
  if from_port == to_port {
    return redirect_uri
  }
  let needle = ":" + from_port.to_string()
  match redirect_uri.find(needle) {
    Some(pos) =>
      redirect_uri.sub(end=pos).to_owned() +
      ":" +
      to_port.to_string() +
      redirect_uri.sub(start=pos + needle.length()).to_owned()
    None => redirect_uri
  }
}

///|
/// Wait for (code, state) from the server, racing a manual paste prompt when
/// one is supplied. Each race task must raise on failure instead of returning
/// an Err value: `any(allow_failure=true)` ignores raised errors but a
/// returned Err counts as success, so a failing or cancelled loser that ran
/// to completion could otherwise overwrite the real winner. The losing server
/// task is torn down by the caller's stop(); a winning paste stops the server
/// itself before returning.
async fn receive_callback(
  auth_url : String,
  server : &CallbackServer,
  prompt : &AuthPromptInteraction?,
) -> CallbackWinner raise OAuthError {
  match prompt {
    Some(p) => {
      let raced : Result[Result[CallbackWinner, OAuthError], Error] = Ok(
        @async.any(
          [
            () => {
              let (code, state) = server.wait_callback()
              Ok(ServerWon(code, state))
            },
            () => {
              let text = p.prompt(
                AuthPromptRequest::Secret(
                  message="Open the login URL in a browser, then paste the full callback URL after signing in: " +
                    auth_url,
                ),
              )
              match parse_pasted_authorization(text) {
                Some(pair) => {
                  // Paste won: release the port immediately.
                  server.stop()
                  Ok(PasteWon(pair.0, pair.1))
                }
                None =>
                  raise OAuthError::ParseError(
                    "pasted login input is missing code/state query parameters; paste the full callback URL",
                  )
              }
            },
          ],
          allow_failure=true,
        ),
      ) catch {
        err => Err(err)
      }
      match raced {
        Ok(Ok(winner)) => winner
        Ok(Err(err)) => raise err
        Err(err) =>
          raise OAuthError::HttpError(
            "callback race failed: " + err.to_string(),
          )
      }
    }
    None => {
      let received = Ok(server.wait_callback()) catch { err => Err(err) }
      match received {
        Ok((code, state)) => ServerWon(code, state)
        Err(err) => raise err
      }
    }
  }
}

///|
/// Parse manually pasted authorization input. Accepts (a) a full callback URL
/// containing code and state query params, or (b) a bare `code=..&state=..`
/// query string. A bare code without state returns None so the caller asks
/// for the full URL.
fn parse_pasted_authorization(input : String) -> (String, String)? {
  let text = input.trim().to_owned()
  let query = match text.find("?") {
    Some(qmark) => text.sub(start=qmark + 1).to_owned()
    None => text
  }
  let code = extract_query_param(query, "code")
  let state = extract_query_param(query, "state")
  match (code, state) {
    (Some(c), Some(s)) =>
      if c.length() > 0 && s.length() > 0 {
        Some((c, s))
      } else {
        None
      }
    _ => None
  }
}

///|
/// Extract one query param value from a query string (or full URL). The
/// native callback impl and the paste parser share this.
fn extract_query_param(path : String, key : String) -> String? {
  let query = match path.find("?") {
    Some(qmark) => path.sub(start=qmark + 1).to_owned()
    None => path
  }
  let prefix = key + "="
  let start = if query.has_prefix(prefix) {
    prefix.length()
  } else {
    match query.find("&" + prefix) {
      Some(pos) => pos + 1 + prefix.length()
      None => return None
    }
  }
  let rest = query.sub(start~).to_owned()
  match rest.find("&") {
    Some(amp) => Some(rest.sub(end=amp).to_owned())
    None => Some(rest)
  }
}

///|
/// Build the authorization URL with PKCE challenge, state, and any extra
/// provider params.
fn build_authorize_url(
  config : PkceFlowConfig,
  pkce : PkcePair,
  state : String,
  redirect_uri : String,
) -> String {
  let mut params = "response_type=code" +
    "&client_id=" +
    config.client_id +
    "&redirect_uri=" +
    url_encode(redirect_uri) +
    "&scope=" +
    url_encode(config.scope) +
    "&code_challenge=" +
    pkce.code_challenge +
    "&code_challenge_method=S256" +
    "&state=" +
    url_encode(state)
  for pair in config.extra_authorize_params {
    params = params + "&" + url_encode(pair.0) + "=" + url_encode(pair.1)
  }
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
  redirect_uri : String,
  transport : &OAuthHttpTransport,
  parse_credential : ((Json) -> Credential raise OAuthError)?,
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
    url_encode(redirect_uri)
  let response = transport.post(OAuthHttpRequest::{
    url: config.token_url,
    body,
    headers,
  })
  let resp_json = @json.parse(response.body) catch {
    err => raise OAuthError::ParseError("token response: " + err.to_string())
  }
  match parse_credential {
    Some(parse) => parse(resp_json)
    None => parse_token_response(resp_json)
  }
}

///|
/// Lenient default token-response parser (kept as the named default for
/// `run_pkce_browser_flow`'s `parse_credential` hook).
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
