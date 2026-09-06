///|
/// OAuth provider for OpenAI/Codex (ChatGPT subscription).
///
/// Login runs the shared PKCE browser flow (codex_browser_login.mbt); this
/// file keeps the token exchange/refresh wire contract and its strict parsing.
/// The client_id is public and shared across all tools (Cline, Codex CLI, Pi).

///|
/// Public client_id shared by all Codex OAuth consumers.
let codex_client_id : String = "app_EMoamEEZ73f0CkXaXp7hrann"

///|
let codex_auth_base : String = "https://auth.openai.com"

///|
let codex_api_base : String = "https://chatgpt.com/backend-api/codex"

///|
/// Encode one form value according to application/x-www-form-urlencoded's
/// RFC 3986 unreserved set. Auth codes/verifiers are normally URL-safe, but
/// the exchange must still be correct if the provider emits a reserved
/// character in either value.
fn codex_form_encode(value : String) -> String {
  let buf = StringBuilder()
  for ch in value {
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
      buf.write_string(codex_hex_upper(code / 16))
      buf.write_string(codex_hex_upper(code % 16))
    }
  }
  buf.to_string()
}

///|
fn codex_hex_upper(value : Int) -> String {
  if value < 10 {
    value.to_string()
  } else {
    (value + 55).unsafe_to_char().to_string()
  }
}

///|
fn ensure_codex_http_success(
  stage : String,
  status : Int,
  body_chars? : Int? = None,
) -> Unit raise @oauth.OAuthError {
  if status < 200 || status >= 300 {
    let body_summary = match body_chars {
      Some(length) => ", body_chars=" + length.to_string()
      None => ""
    }
    raise @oauth.OAuthError::HttpError(
      "Codex OAuth HTTP error (stage=" +
      stage +
      ", status=" +
      status.to_string() +
      body_summary +
      ")",
    )
  }
}

///|
/// OpenAI/Codex OAuth provider.
pub(all) struct CodexOAuth {
  /// Optional injected transport for deterministic protocol tests and hosts.
  transport : &@oauth.OAuthHttpTransport?
}

///|
pub fn CodexOAuth::CodexOAuth(
  transport? : &@oauth.OAuthHttpTransport? = None,
) -> CodexOAuth {
  CodexOAuth::{ transport, }
}

///|
/// Provider-independent POST seam. The default transport enforces the
/// 30-second OAuth HTTP deadline; injected transports preserve exact request
/// observability in tests.
async fn CodexOAuth::post(
  self : CodexOAuth,
  request : @oauth.OAuthHttpRequest,
) -> @oauth.OAuthHttpResponse raise @oauth.OAuthError {
  match self.transport {
    Some(transport) => transport.post(request)
    None => {
      let default_transport = @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport()
      let transport : &@oauth.OAuthHttpTransport = default_transport
      transport.post(request)
    }
  }
}

///|
pub impl @oauth.OAuthProvider for CodexOAuth with fn provider_id(
  _self : CodexOAuth,
) -> String {
  "openai-codex"
}

///|
pub impl @oauth.OAuthProvider for CodexOAuth with fn refresh(
  self : CodexOAuth,
  credential : @oauth.Credential,
) -> @oauth.Credential raise @oauth.OAuthError {
  let headers : Map[String, String] = Map([
    ("Content-Type", "application/x-www-form-urlencoded"),
  ])
  let body = "grant_type=refresh_token" +
    "&client_id=" +
    codex_form_encode(codex_client_id) +
    "&refresh_token=" +
    codex_form_encode(credential.refresh_token)
  let token_response = self.post(@oauth.OAuthHttpRequest::{
    url: codex_auth_base + "/oauth/token",
    body,
    headers,
  })
  ensure_codex_http_success(
    "refresh",
    token_response.status,
    body_chars=Some(token_response.body.length()),
  )
  let token_text = token_response.body
  let token_json = @json.parse(token_text) catch {
    err =>
      raise @oauth.OAuthError::ParseError(
        "refresh response: " + err.to_string(),
      )
  }
  // OpenAI rotates refresh_token on each refresh — must use the new one.
  parse_token_response(token_json)
}

///|
pub impl @oauth.OAuthProvider for CodexOAuth with fn to_auth(
  _self : CodexOAuth,
  credential : @oauth.Credential,
) -> @oauth.AuthHeader {
  @oauth.AuthHeader::Bearer(credential.access_token)
}

///|
/// Parse a standard OAuth token response into a Credential.
/// Extracts account_id from the JWT if present (stored in metadata).
fn parse_token_response(
  json : Json,
) -> @oauth.Credential raise @oauth.OAuthError {
  match json {
    Json::Object(map) => {
      match map.get("error") {
        Some(Json::String(err_code)) =>
          match err_code {
            "invalid_grant" => raise @oauth.OAuthError::InvalidGrant
            other => raise @oauth.OAuthError::HttpError("token error: " + other)
          }
        _ => ()
      }
      let access_token = match map.get("access_token") {
        Some(Json::String(s)) if s.length() > 0 => s
        Some(Json::String(_)) =>
          raise @oauth.OAuthError::ParseError("access_token must not be empty")
        _ => raise @oauth.OAuthError::ParseError("missing access_token")
      }
      let refresh_token = match map.get("refresh_token") {
        Some(Json::String(s)) if s.length() > 0 => s
        Some(Json::String(_)) =>
          raise @oauth.OAuthError::ParseError("refresh_token must not be empty")
        _ => raise @oauth.OAuthError::ParseError("missing refresh_token")
      }
      let expires_in = match map.get("expires_in") {
        Some(Json::Number(n, ..)) =>
          match parse_codex_positive_integer(n) {
            Some(value) => value
            None =>
              raise @oauth.OAuthError::ParseError(
                "expires_in must be a finite positive integer",
              )
          }
        _ => raise @oauth.OAuthError::ParseError("missing expires_in")
      }
      let token_type = match map.get("token_type") {
        Some(Json::String(s)) if s.length() > 0 => s
        Some(Json::String(_)) => "Bearer"
        _ => "Bearer"
      }
      let account_id = match extract_codex_account_id(access_token) {
        Some(value) => value
        None =>
          raise @oauth.OAuthError::ParseError(
            "access_token JWT is missing chatgpt account id claim",
          )
      }
      let metadata : Map[String, String] = Map([("account_id", account_id)])
      let now_secs = (@async.now() / 1000L).to_int()
      @oauth.Credential::Credential(
        access_token~,
        refresh_token~,
        expires_at=now_secs + expires_in,
        token_type~,
        metadata~,
      )
    }
    _ => raise @oauth.OAuthError::ParseError("token response not an object")
  }
}

///|
/// Strict token lifetime parser shared by initial exchange and refresh.
fn parse_codex_positive_integer(value : Double) -> Int? {
  if value.is_nan() || value.is_inf() || value <= 0.0 {
    return None
  }
  let integer = value.to_int()
  if integer <= 0 || value != integer.to_double() {
    None
  } else {
    Some(integer)
  }
}

///|
/// Decode the provider's JWT account claim without exposing any other token
/// payload in diagnostics. Codex requires this claim for API requests. OpenAI
/// nests it inside the namespaced auth claim object (verified against
/// codex-rs IdClaims and pi's JWT_CLAIM_PATH lookup):
/// {"https://api.openai.com/auth":{"chatgpt_account_id":"..."}}
fn extract_codex_account_id(access_token : String) -> String? {
  let segments = access_token.split(".").to_array()
  if segments.length() < 2 {
    return None
  }
  let payload_bytes = @base64.decode(segments[1], url_safe=true) catch {
    _ => return None
  }
  let payload_text = @utf8.decode(payload_bytes) catch { _ => return None }
  let payload = @json.parse(payload_text) catch { _ => return None }
  match payload {
    Json::Object(map) =>
      match map.get("https://api.openai.com/auth") {
        Some(Json::Object(auth)) =>
          match auth.get("chatgpt_account_id") {
            Some(Json::String(value)) if value.length() > 0 => Some(value)
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// The API base URL for Codex OAuth mode.
/// When using OAuth (ChatGPT subscription), requests go to
/// chatgpt.com/backend-api/codex instead of api.openai.com/v1.
pub fn codex_oauth_api_base() -> String {
  codex_api_base
}
