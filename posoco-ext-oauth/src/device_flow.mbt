///|
/// device_flow.mbt — generic RFC 8628 device authorization grant polling.
///
/// Providers supply their endpoints + client_id; this module handles the
/// shared polling logic (interval, slow_down backoff, timeout, cancellation).

///|
/// Configuration for a device authorization flow.
pub(all) struct DeviceFlowConfig {
  client_id : String
  device_auth_endpoint : String // POST to get device_code + user_code
  token_endpoint : String // POST to poll for access_token
  scope : String // e.g. "openid profile email offline_access"
}

///|
/// Response from the device authorization endpoint (RFC 8628 §3.2).
pub(all) struct DeviceAuthResponse {
  device_code : String
  user_code : String
  verification_uri : String
  verification_uri_complete : String? // URI with user_code embedded
  expires_in : Int // seconds until device_code expires
  interval : Int // minimum poll interval in seconds
}

///|
/// Parse the device authorization response.
fn parse_device_auth_response(json : Json) -> DeviceAuthResponse? {
  match json {
    Json::Object(map) => {
      let device_code = match map.get("device_code") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let user_code = match map.get("user_code") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let verification_uri = match map.get("verification_uri") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let verification_uri_complete = match
        map.get("verification_uri_complete") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
      let expires_in = match map.get("expires_in") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => 900 // 15 min default
      }
      let interval = match map.get("interval") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => 5 // 5s default
      }
      Some({
        device_code,
        user_code,
        verification_uri,
        verification_uri_complete,
        expires_in,
        interval,
      })
    }
    _ => None
  }
}

///|
/// Request a device code from the provider. POST form-encoded body;
/// returns the device auth response or raises OAuthError.
async fn request_device_code(
  config : DeviceFlowConfig,
) -> DeviceAuthResponse raise OAuthError {
  let headers : Map[String, String] = Map([
    ("Content-Type", "application/x-www-form-urlencoded"),
  ])
  let body = "client_id=" + config.client_id + "&scope=" + config.scope
  let (_, body_data) = @http.post(config.device_auth_endpoint, body, headers~) catch {
    err => raise OAuthError::HttpError(err.to_string())
  }
  let body_text = body_data.text() catch {
    err =>
      raise OAuthError::HttpError("device auth body read: " + err.to_string())
  }
  let resp_json = @json.parse(body_text) catch {
    err =>
      raise OAuthError::ParseError("device auth response: " + err.to_string())
  }
  match parse_device_auth_response(resp_json) {
    Some(dar) => dar
    None =>
      raise OAuthError::ParseError(
        "missing device_code/user_code/verification_uri",
      )
  }
}

///|
/// Poll the token endpoint once. Returns Credential on success,
/// raises AuthPending/SlowDown for retry, or terminal OAuthError.
async fn poll_token(
  config : DeviceFlowConfig,
  device_code : String,
) -> Credential raise OAuthError {
  let headers : Map[String, String] = Map([
    ("Content-Type", "application/x-www-form-urlencoded"),
  ])
  let body = "client_id=" +
    config.client_id +
    "&device_code=" +
    device_code +
    "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
  let (_, body_data) = @http.post(config.token_endpoint, body, headers~) catch {
    err => raise OAuthError::HttpError(err.to_string())
  }
  let body_text = body_data.text() catch {
    err => raise OAuthError::HttpError("token body read: " + err.to_string())
  }
  let resp_json = @json.parse(body_text) catch {
    err => raise OAuthError::ParseError("token response: " + err.to_string())
  }
  match resp_json {
    Json::Object(map) => {
      // Check for error response (RFC 8628 §3.5)
      match map.get("error") {
        Some(Json::String(err_code)) =>
          match err_code {
            "authorization_pending" => raise AuthPending
            "slow_down" => raise SlowDown
            "access_denied" => raise AccessDenied
            "expired_token" => raise ExpiredToken
            other => raise OAuthError::HttpError("token error: " + other)
          }
        _ => ()
      }
      // Success response
      let access_token = match map.get("access_token") {
        Some(Json::String(s)) => s
        _ =>
          raise OAuthError::ParseError(
            "missing access_token in success response",
          )
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
      // @async.now() returns ms since epoch; convert to seconds.
      let now_secs = (@async.now() / 1000L).to_int()
      let expires_at = now_secs + expires_in
      Credential::Credential(
        access_token~,
        refresh_token~,
        expires_at~,
        token_type~,
      )
    }
    _ => raise OAuthError::ParseError("token response is not an object")
  }
}

///|
/// Run the complete device flow: request code → notify user → poll.
///
/// Polls at `interval` seconds, backing off by +5s on slow_down.
/// Times out after `expires_in` seconds. Checks `interaction.is_cancelled`
/// between polls; raises Cancelled if the user aborts.
pub async fn run_device_flow(
  config : DeviceFlowConfig,
  interaction : &AuthInteraction,
) -> Credential raise OAuthError {
  let dar = request_device_code(config)
  // Notify user: show the verification URI + user code.
  interaction.notify(
    AuthMessage::DeviceCode(dar.verification_uri, dar.user_code),
  )
  // Poll loop
  let now_secs = (@async.now() / 1000L).to_int()
  let deadline = now_secs + dar.expires_in
  let mut interval = dar.interval
  while true {
    if interaction.is_cancelled() {
      raise Cancelled
    }
    let check_secs = (@async.now() / 1000L).to_int()
    if check_secs >= deadline {
      raise ExpiredToken
    }
    @async.sleep(interval) catch {
      err =>
        raise OAuthError::HttpError("sleep interrupted: " + err.to_string())
    }
    let result = poll_token(config, dar.device_code) catch {
      AuthPending => continue
      SlowDown => {
        interval = interval + 5
        continue
      }
      other => raise other
    }
    return result
  }
  abort("unreachable")
}
