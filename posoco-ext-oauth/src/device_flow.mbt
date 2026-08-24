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
  scope : String // retained for provider metadata; Kimi's wire omits it
  /// Provider-declared default headers merged into every device-flow POST.
  /// Providers that need product identity headers (User-Agent, X-Msh-*, etc.)
  /// set them here; the generic RFC 8628 logic stays provider-agnostic.
  /// `Content-Type` and `Accept` set by the flow always override these.
  default_headers : Map[String, String]
}

///|
/// Build a `DeviceFlowConfig` with a sane empty `default_headers`. Providers
/// that carry identity headers call `.with_default_headers` after.
pub fn DeviceFlowConfig::DeviceFlowConfig(
  client_id~ : String,
  device_auth_endpoint~ : String,
  token_endpoint~ : String,
  scope? : String = "",
) -> DeviceFlowConfig {
  {
    client_id,
    device_auth_endpoint,
    token_endpoint,
    scope,
    default_headers: Map::from_array([]),
  }
}

///|
/// Return a copy of `self` with `headers` merged into `default_headers`.
/// Callers' own request-scoped `Content-Type` / `Accept` still win.
pub fn DeviceFlowConfig::with_default_headers(
  self : DeviceFlowConfig,
  headers : Map[String, String],
) -> DeviceFlowConfig {
  let merged = Map::from_array([])
  for k, v in self.default_headers {
    merged[k] = v
  }
  for k, v in headers {
    merged[k] = v
  }
  { ..self, default_headers: merged }
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
/// Parse the device authorization response. Kimi Code follows pi's strict
/// contract: all four device/verification strings are required and non-empty.
fn parse_device_auth_response(json : Json) -> DeviceAuthResponse? {
  match json {
    Json::Object(map) => {
      let device_code = match map.get("device_code") {
        Some(Json::String(s)) => if s.length() > 0 { s } else { return None }
        _ => return None
      }
      let user_code = match map.get("user_code") {
        Some(Json::String(s)) => if s.length() > 0 { s } else { return None }
        _ => return None
      }
      let verification_uri = match map.get("verification_uri") {
        Some(Json::String(s)) =>
          if s.length() > 0 && is_trusted_http_uri(s) {
            s
          } else {
            return None
          }
        _ => return None
      }
      let verification_uri_complete = match
        map.get("verification_uri_complete") {
        Some(Json::String(s)) =>
          if s.length() > 0 && is_trusted_http_uri(s) {
            Some(s)
          } else {
            return None
          }
        _ => return None
      }
      let expires_in = match map.get("expires_in") {
        Some(Json::Number(n, ..)) =>
          match parse_positive_integer(n) {
            Some(value) => value
            None => return None
          }
        _ => 900 // RFC 8628 default is 15 minutes in the pi helper.
      }
      let interval = match map.get("interval") {
        Some(Json::Number(n, ..)) =>
          match parse_positive_integer(n) {
            Some(value) => value
            None => return None
          }
        _ => 5 // RFC 8628 default is 5 seconds.
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
/// Parse only finite, strictly positive integer JSON numbers.  Truncating a
/// fractional expiry/interval would silently alter provider timing semantics.
fn parse_positive_integer(value : Double) -> Int? {
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
/// OAuth device responses carry a URL that the host may open.  Accept only
/// absolute HTTP(S) URLs and reject whitespace/control characters; in
/// particular, never hand a javascript:/file: or empty-host URI to a host UI.
fn is_trusted_http_uri(value : String) -> Bool {
  let host = if value.has_prefix("https://") {
    value.sub(start=8)
  } else if value.has_prefix("http://") {
    value.sub(start=7)
  } else {
    return false
  }
  if host.length() == 0 {
    return false
  }
  for ch in host {
    if ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch.to_int() < 32 {
      return false
    }
  }
  true
}

///|
/// Merge a config's `default_headers` with the flow's own headers. The flow's
/// `Content-Type` / `Accept` always override any same-named default, so the
/// RFC 8628 form/JSON wire contract stays authoritative.
fn merge_flow_headers(
  defaults : Map[String, String],
  flow_headers : Map[String, String],
) -> Map[String, String] {
  let out : Map[String, String] = Map::from_array([])
  for k, v in defaults {
    out[k] = v
  }
  for k, v in flow_headers {
    out[k] = v
  }
  out
}

///|
/// Request a device code from the provider. POST form-encoded body;
/// returns the device auth response or raises OAuthError.
async fn request_device_code(
  config : DeviceFlowConfig,
  transport : &OAuthHttpTransport,
) -> DeviceAuthResponse raise OAuthError {
  let flow_headers : Map[String, String] = Map([
    ("Content-Type", "application/x-www-form-urlencoded"),
    ("Accept", "application/json"),
  ])
  let headers = merge_flow_headers(config.default_headers, flow_headers)
  // Kimi Code follows pi's wire contract: scope is not sent on this endpoint.
  let body = "client_id=" + url_encode(config.client_id)
  let response = transport.post(OAuthHttpRequest::{
    url: config.device_auth_endpoint,
    body,
    headers,
  })
  if response.status < 200 || response.status >= 300 {
    raise OAuthError::HttpError(
      "device auth HTTP status=" +
      response.status.to_string() +
      ", body_chars=" +
      response.body.length().to_string(),
    )
  }
  let resp_json = @json.parse(response.body) catch {
    err =>
      raise OAuthError::ParseError("device auth response: " + err.to_string())
  }
  match parse_device_auth_response(resp_json) {
    Some(dar) => dar
    None =>
      raise OAuthError::ParseError(
        "missing device_code/user_code/verification_uri_complete or invalid http(s) URI in verification fields",
      )
  }
}

///|
/// Token polling outcome. RFC 8628 pending/slow_down are control flow rather
/// than failures; terminal statuses remain typed OAuth errors.
priv enum PollTokenResult {
  Pending
  SlowDown(Int) // server interval, or 0 when omitted
  Complete(Credential)
  Failed(OAuthError)
}

///|
/// Poll the token endpoint once. The response body is parsed even for HTTP
/// 400 because RFC 8628 uses that status for authorization_pending/slow_down.
async fn poll_token(
  config : DeviceFlowConfig,
  device_code : String,
  transport : &OAuthHttpTransport,
) -> PollTokenResult raise OAuthError {
  let flow_headers : Map[String, String] = Map([
    ("Content-Type", "application/x-www-form-urlencoded"),
    ("Accept", "application/json"),
  ])
  let headers = merge_flow_headers(config.default_headers, flow_headers)
  let body = "client_id=" +
    url_encode(config.client_id) +
    "&device_code=" +
    url_encode(device_code) +
    "&grant_type=" +
    url_encode("urn:ietf:params:oauth:grant-type:device_code")
  let response = transport.post(OAuthHttpRequest::{
    url: config.token_endpoint,
    body,
    headers,
  })
  // Server failures are terminal for this poll attempt.  Do not parse an
  // arbitrary HTML/proxy body as OAuth JSON; preserve only safe diagnostics.
  if response.status >= 500 {
    return Failed(
      HttpError(
        "token HTTP status=" +
        response.status.to_string() +
        ", body_chars=" +
        response.body.length().to_string(),
      ),
    )
  }
  let resp_json = @json.parse(response.body) catch {
    err => raise OAuthError::ParseError("token response: " + err.to_string())
  }
  match resp_json {
    Json::Object(map) =>
      // Check for error response (RFC 8628 §3.5).
      match map.get("error") {
        Some(Json::String(err_code)) =>
          match err_code {
            "authorization_pending" => Pending
            "slow_down" => {
              let interval = match map.get("interval") {
                Some(Json::Number(n, ..)) =>
                  match parse_positive_integer(n) {
                    Some(value) => value
                    None =>
                      return Failed(
                        ParseError(
                          "invalid interval in slow_down token response",
                        ),
                      )
                  }
                _ => 0
              }
              SlowDown(interval)
            }
            "access_denied" => Failed(AccessDenied)
            "expired_token" => Failed(ExpiredToken)
            "invalid_grant" => Failed(InvalidGrant)
            other =>
              Failed(
                HttpError(
                  "token error=" +
                  other +
                  ", status=" +
                  response.status.to_string(),
                ),
              )
          }
        _ => {
          if response.status < 200 || response.status >= 300 {
            return Failed(
              HttpError("token HTTP status=" + response.status.to_string()),
            )
          }
          // Success response. pi requires all token fields that are needed to
          // persist and refresh a subscription credential.
          let access_token = match map.get("access_token") {
            Some(Json::String(s)) =>
              if s.length() > 0 {
                s
              } else {
                return Failed(
                  ParseError("missing access_token in success response"),
                )
              }
            _ =>
              return Failed(
                ParseError("missing access_token in success response"),
              )
          }
          let refresh_token = match map.get("refresh_token") {
            Some(Json::String(s)) =>
              if s.length() > 0 {
                s
              } else {
                return Failed(
                  ParseError("missing refresh_token in success response"),
                )
              }
            _ =>
              return Failed(
                ParseError("missing refresh_token in success response"),
              )
          }
          let expires_in = match map.get("expires_in") {
            Some(Json::Number(n, ..)) =>
              match parse_positive_integer(n) {
                Some(value) => value
                None =>
                  return Failed(
                    ParseError("invalid expires_in in success response"),
                  )
              }
            _ =>
              return Failed(
                ParseError("missing expires_in in success response"),
              )
          }
          let token_type = match map.get("token_type") {
            Some(Json::String(s)) => if s.length() > 0 { s } else { "Bearer" }
            _ => "Bearer"
          }
          let now_secs = (@async.now() / 1000L).to_int()
          Complete(
            Credential::Credential(
              access_token~,
              refresh_token~,
              expires_at=now_secs + expires_in,
              token_type~,
            ),
          )
        }
      }
    _ => Failed(ParseError("token response is not an object"))
  }
}

///|
/// Run the complete device flow with the default async HTTP transport.
///
/// Native/js only: this convenience constructs a `DefaultOAuthHttpTransport`,
/// whose `OAuthHttpTransport` impl is compiled only on those backends. On
/// wasm/wasm-gc, use `run_device_flow_with_transport` with a host-supplied
/// transport.
#cfg(any(target="native", target="js"))
pub async fn run_device_flow(
  config : DeviceFlowConfig,
  interaction : &AuthInteraction,
) -> Credential raise OAuthError {
  let default_transport = DefaultOAuthHttpTransport::DefaultOAuthHttpTransport()
  let transport : &OAuthHttpTransport = default_transport
  run_device_flow_with_transport(config, interaction, transport)
}

///|
#cfg(not(any(target="native", target="js")))
pub fn run_device_flow(
  _config : DeviceFlowConfig,
  _interaction : &AuthInteraction,
) -> Credential raise OAuthError {
  raise Cancelled
}

///|
/// Run a device flow with an injected HTTP transport. This is the canonical
/// seam for deterministic tests and hosts that need explicit request tracing.
pub async fn run_device_flow_with_transport(
  config : DeviceFlowConfig,
  interaction : &AuthInteraction,
  transport : &OAuthHttpTransport,
) -> Credential raise OAuthError {
  let dar = request_device_code(config, transport)
  let verification_uri = match dar.verification_uri_complete {
    Some(uri) => uri
    None => dar.verification_uri
  }
  interaction.notify(AuthMessage::DeviceCode(verification_uri, dar.user_code))
  let now_secs = (@async.now() / 1000L).to_int()
  let deadline = now_secs + dar.expires_in
  let mut interval = dar.interval
  while (@async.now() / 1000L).to_int() < deadline {
    if interaction.is_cancelled() {
      raise Cancelled
    }
    @async.sleep(interval) catch {
      err =>
        raise OAuthError::HttpError("sleep interrupted: " + err.to_string())
    }
    let result = poll_token(config, dar.device_code, transport)
    match result {
      Pending => ()
      SlowDown(server_interval) =>
        interval = if server_interval > 0 {
          server_interval
        } else {
          interval + 5
        }
      Complete(credential) => return credential
      Failed(error) => raise error
    }
  }
  raise ExpiredToken
}
