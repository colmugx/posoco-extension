///|
/// codex_oauth.mbt — OAuth provider for OpenAI/Codex (ChatGPT subscription).
///
/// OpenAI's device flow is a CUSTOM protocol (not RFC 8628):
/// 1. POST to device auth endpoint → get {device_auth_id, user_code, interval}
/// 2. User visits verification URL + enters user_code
/// 3. Poll token endpoint → get {authorization_code, code_verifier}
///    (code_verifier is SERVER-GENERATED, not client-generated)
/// 4. Exchange authorization_code for tokens via standard OAuth code grant
///
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
  let buf = StringBuilder::new()
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
/// OpenAI/Codex OAuth provider via custom device flow.
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
/// Classification of one Codex device-token poll response.  Pending states
/// are explicit protocol values; malformed or unknown responses never get
/// mistaken for another pending poll.
priv enum CodexPollResponse {
  Pending
  SlowDown
  Ready(String, String)
}

///|
/// Parse an interval from the OpenAI device-auth response. Pi accepts both a
/// JSON number and a numeric string; the HTTP service has emitted both forms
/// over time. Store milliseconds because `@async.sleep` takes milliseconds.
fn parse_codex_interval_ms(value : Json) -> Int? {
  let seconds = match value {
    Json::Number(number, ..) => number
    Json::String(text) => @string.parse_double(text) catch { _ => return None }
    _ => return None
  }
  if seconds.is_nan() || seconds.is_inf() || seconds < 0.0 {
    return None
  }
  let milliseconds = (seconds * 1000.0).to_int()
  Some(if milliseconds < 1000 { 1000 } else { milliseconds })
}

///|
/// Extract the provider error code from either the legacy string form or the
/// object form used by the current device-token endpoint.
fn parse_codex_error_code(value : Json) -> String raise @oauth.OAuthError {
  match value {
    Json::String(code) if code.length() > 0 => code
    Json::String(_) =>
      raise @oauth.OAuthError::ParseError(
        "Codex OAuth poll response error code must not be empty",
      )
    Json::Object(fields) =>
      match fields.get("code") {
        Some(Json::String(code)) if code.length() > 0 => code
        Some(Json::String(_)) =>
          raise @oauth.OAuthError::ParseError(
            "Codex OAuth poll response error code must not be empty",
          )
        _ =>
          raise @oauth.OAuthError::ParseError(
            "Codex OAuth poll response error object must contain a string code",
          )
      }
    _ =>
      raise @oauth.OAuthError::ParseError(
        "Codex OAuth poll response error must be a string or object with a string code",
      )
  }
}

///|
/// Decode one poll response without exposing provider payloads in diagnostics.
/// Pi treats HTTP 403/404 as pending, then accepts either a string error code
/// or `{error:{code}}` for the JSON response. Credentials are complete only
/// when both authorization_code and code_verifier are present.
fn parse_codex_poll_response(
  status : Int,
  body : String,
) -> CodexPollResponse raise @oauth.OAuthError {
  // OpenAI uses both statuses for "not authorized yet". This status rule is
  // intentionally checked before parsing: the pending body may be empty or
  // otherwise non-JSON on one of the endpoints.
  if status == 403 || status == 404 {
    return Pending
  }
  let json = @json.parse(body) catch {
    _ =>
      raise @oauth.OAuthError::ParseError(
        "Codex OAuth poll response is not valid JSON",
      )
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ =>
      raise @oauth.OAuthError::ParseError(
        "Codex OAuth poll response must be an object",
      )
  }
  match fields.get("error") {
    Some(error) => {
      let code = parse_codex_error_code(error)
      match code {
        "authorization_pending" | "deviceauth_authorization_pending" => Pending
        "slow_down" => SlowDown
        "access_denied" => raise @oauth.OAuthError::AccessDenied
        "expired_token" => raise @oauth.OAuthError::ExpiredToken
        "invalid_grant" => raise @oauth.OAuthError::InvalidGrant
        other =>
          raise @oauth.OAuthError::ParseError(
            "Codex OAuth poll response contains an unknown error code: " + other,
          )
      }
    }
    None => {
      if status < 200 || status >= 300 {
        raise @oauth.OAuthError::HttpError(
          "Codex OAuth poll failed (status=" + status.to_string() + ")",
        )
      }
      let authorization_code = match fields.get("authorization_code") {
        Some(Json::String(value)) if value.length() > 0 => value
        Some(Json::String(_)) =>
          raise @oauth.OAuthError::ParseError(
            "Codex OAuth poll response authorization_code must not be empty",
          )
        Some(_) =>
          raise @oauth.OAuthError::ParseError(
            "Codex OAuth poll response authorization_code must be a string",
          )
        None =>
          raise @oauth.OAuthError::ParseError(
            "Codex OAuth poll response is missing authorization_code",
          )
      }
      let code_verifier = match fields.get("code_verifier") {
        Some(Json::String(value)) if value.length() > 0 => value
        Some(Json::String(_)) =>
          raise @oauth.OAuthError::ParseError(
            "Codex OAuth poll response code_verifier must not be empty",
          )
        Some(_) =>
          raise @oauth.OAuthError::ParseError(
            "Codex OAuth poll response code_verifier must be a string",
          )
        None =>
          raise @oauth.OAuthError::ParseError(
            "Codex OAuth poll response is missing code_verifier",
          )
      }
      Ready(authorization_code, code_verifier)
    }
  }
}

///|
/// Decode one successful-status poll body. Kept as a small compatibility
/// helper for package-local conformance tests and callers that have already
/// checked the HTTP status.
fn parse_codex_poll_body(
  body : String,
) -> CodexPollResponse raise @oauth.OAuthError {
  parse_codex_poll_response(200, body)
}

///|
pub impl @oauth.OAuthProvider for CodexOAuth with fn provider_id(
  _self : CodexOAuth,
) -> String {
  "openai-codex"
}

///|
pub impl @oauth.OAuthProvider for CodexOAuth with fn login(
  self : CodexOAuth,
  interaction : &@oauth.AuthInteraction,
) -> @oauth.Credential raise @oauth.OAuthError {
  // Step 1: Request device auth (custom OpenAI protocol, not RFC 8628).
  let device_auth_json = Json::object(
    Map([("client_id", Json::string(codex_client_id))]),
  )
  let headers_json : Map[String, String] = Map([
    ("Content-Type", "application/json"),
    ("Accept", "application/json"),
  ])
  let device_response = self.post(@oauth.OAuthHttpRequest::{
    url: codex_auth_base + "/api/accounts/deviceauth/usercode",
    body: device_auth_json.stringify(),
    headers: headers_json,
  })
  ensure_codex_http_success(
    "device_auth",
    device_response.status,
    body_chars=Some(device_response.body.length()),
  )
  let body_text = device_response.body
  let resp_json = @json.parse(body_text) catch {
    err =>
      raise @oauth.OAuthError::ParseError("device auth: " + err.to_string())
  }
  let (device_auth_id, user_code, initial_interval_ms) = match resp_json {
    Json::Object(map) => {
      let dai = match map.get("device_auth_id") {
        Some(Json::String(s)) if s.length() > 0 => s
        _ => raise @oauth.OAuthError::ParseError("missing device_auth_id")
      }
      let uc = match map.get("user_code") {
        Some(Json::String(s)) if s.length() > 0 => s
        _ => raise @oauth.OAuthError::ParseError("missing user_code")
      }
      let iv = match map.get("interval") {
        Some(value) =>
          match parse_codex_interval_ms(value) {
            Some(interval_ms) => interval_ms
            None =>
              raise @oauth.OAuthError::ParseError(
                "invalid device auth interval; expected a finite non-negative number or numeric string",
              )
          }
        None =>
          raise @oauth.OAuthError::ParseError(
            "device auth response is missing interval",
          )
      }
      (dai, uc, iv)
    }
    _ =>
      raise @oauth.OAuthError::ParseError("device auth response not an object")
  }

  // Step 2: Notify user to visit verification URL + enter code.
  interaction.notify(
    @oauth.AuthMessage::DeviceCode(codex_auth_base + "/codex/device", user_code),
  )

  // Step 3: Poll for authorization_code + code_verifier (server-generated).
  let mut interval_ms = initial_interval_ms
  let poll_body = Json::object(
    Map([
      ("device_auth_id", Json::string(device_auth_id)),
      ("user_code", Json::string(user_code)),
    ]),
  )
  let mut auth_code = ""
  let mut code_verifier = ""
  let deadline = (@async.now() / 1000L).to_int() + 900 // 15 min timeout
  let mut first_poll = true
  while true {
    if interaction.is_cancelled() {
      raise @oauth.OAuthError::Cancelled
    }
    let now = (@async.now() / 1000L).to_int()
    if now >= deadline {
      raise @oauth.OAuthError::ExpiredToken
    }
    if !first_poll {
      @async.sleep(interval_ms) catch {
        err =>
          raise @oauth.OAuthError::HttpError("poll sleep: " + err.to_string())
      }
    }
    first_poll = false
    let poll_response = self.post(@oauth.OAuthHttpRequest::{
      url: codex_auth_base + "/api/accounts/deviceauth/token",
      body: poll_body.stringify(),
      headers: headers_json,
    })
    match parse_codex_poll_response(poll_response.status, poll_response.body) {
      Pending => ()
      SlowDown => interval_ms = interval_ms + 5000
      Ready(code, verifier) => {
        auth_code = code
        code_verifier = verifier
        break
      }
    }
  }

  // Step 4: Exchange authorization_code for tokens.
  let token_headers : Map[String, String] = Map([
    ("Content-Type", "application/x-www-form-urlencoded"),
  ])
  let token_body = "grant_type=authorization_code" +
    "&client_id=" +
    codex_form_encode(codex_client_id) +
    "&code=" +
    codex_form_encode(auth_code) +
    "&code_verifier=" +
    codex_form_encode(code_verifier) +
    "&redirect_uri=" +
    codex_form_encode(codex_auth_base + "/deviceauth/callback")
  let token_response = self.post(@oauth.OAuthHttpRequest::{
    url: codex_auth_base + "/oauth/token",
    body: token_body,
    headers: token_headers,
  })
  ensure_codex_http_success(
    "token_exchange",
    token_response.status,
    body_chars=Some(token_response.body.length()),
  )
  let token_text = token_response.body
  let token_json = @json.parse(token_text) catch {
    err =>
      raise @oauth.OAuthError::ParseError("token response: " + err.to_string())
  }
  parse_token_response(token_json)
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
/// payload in diagnostics. Codex requires this claim for API requests.
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
      match map.get("https://api.openai.com/auth.chatgpt_account_id") {
        Some(Json::String(value)) if value.length() > 0 => Some(value)
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
