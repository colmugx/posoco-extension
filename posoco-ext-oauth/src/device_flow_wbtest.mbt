///|
/// The fake transport drives the real request_device_code path. These tests
/// protect the exact form-urlencoded + Accept JSON wire contract used by pi.

///|
struct RecordingOAuthTransport {
  requests : Array[OAuthHttpRequest]
  response : OAuthHttpResponse
}

///|
pub impl OAuthHttpTransport for RecordingOAuthTransport with fn post(
  self : RecordingOAuthTransport,
  request : OAuthHttpRequest,
) -> OAuthHttpResponse {
  self.requests.push(request)
  self.response
}

///|
fn header_value(headers : Map[String, String], key : String) -> String raise {
  match headers.get(key) {
    Some(value) => value
    None => fail("missing header: " + key)
  }
}

///|
async test "device request matches pi form wire" {
  let success_body =
    #|{"device_code":"device","user_code":"user","verification_uri":"https://auth.kimi.com/device","verification_uri_complete":"https://auth.kimi.com/device?code=user","expires_in":900,"interval":5}
  let transport_impl = RecordingOAuthTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: success_body },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let config : DeviceFlowConfig = {
    client_id: "client-id",
    device_auth_endpoint: "https://auth.kimi.com/api/oauth/device_authorization",
    token_endpoint: "https://auth.kimi.com/api/oauth/token",
    scope: "openid profile email offline_access",
    default_headers: Map::from_array([]),
  }
  let result = Ok(request_device_code(config, transport)) catch {
    error => Err(error)
  }
  match result {
    Ok(response) => assert_eq(response.device_code, "device")
    Err(error) => fail("unexpected request failure: " + Show::to_string(error))
  }
  assert_eq(transport_impl.requests.length(), 1)
  let request = transport_impl.requests[0]
  assert_eq(request.url, config.device_auth_endpoint)
  assert_eq(
    header_value(request.headers, "Content-Type"),
    "application/x-www-form-urlencoded",
  )
  assert_eq(header_value(request.headers, "Accept"), "application/json")
  assert_eq(request.body, "client_id=client-id")
}

///|
async test "device response missing fields stays typed" {
  let missing_field_body =
    #|{"device_code":"device","user_code":"user","verification_uri":"https://auth.kimi.com/device"}
  let transport_impl = RecordingOAuthTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: missing_field_body },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let config : DeviceFlowConfig = {
    client_id: "client-id",
    device_auth_endpoint: "https://auth.kimi.com/api/oauth/device_authorization",
    token_endpoint: "https://auth.kimi.com/api/oauth/token",
    scope: "",
    default_headers: Map::from_array([]),
  }
  let result = Ok(request_device_code(config, transport)) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::ParseError(detail)) =>
      assert_true(detail.contains("verification_uri_complete"))
    Err(error) =>
      fail("expected typed parse error, got: " + Show::to_string(error))
    Ok(_) => fail("expected missing-field parse error")
  }
}

///|
async test "device response rejects untrusted verification URI" {
  let body =
    #|{"device_code":"device","user_code":"user","verification_uri":"javascript:alert(1)","verification_uri_complete":"https://auth.kimi.com/device?code=user"}
  let transport_impl = RecordingOAuthTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let config : DeviceFlowConfig = {
    client_id: "client-id",
    device_auth_endpoint: "https://auth.kimi.com/device",
    token_endpoint: "https://auth.kimi.com/token",
    scope: "ignored",
    default_headers: Map::from_array([]),
  }
  let result = Ok(request_device_code(config, transport)) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::ParseError(detail)) =>
      assert_true(detail.contains("invalid http(s) URI"))
    Err(error) =>
      fail("expected URI parse error, got: " + Show::to_string(error))
    Ok(_) => fail("untrusted URI must not be returned to the host")
  }
}

///|
async test "token request matches pi form wire and parses credential" {
  let token_body =
    #|{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer"}
  let transport_impl = RecordingOAuthTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: token_body },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let config : DeviceFlowConfig = {
    client_id: "client-id",
    device_auth_endpoint: "https://auth.kimi.com/device",
    token_endpoint: "https://auth.kimi.com/token",
    scope: "ignored",
    default_headers: Map::from_array([]),
  }
  let result = poll_token(config, "device/code", transport)
  match result {
    PollTokenResult::Complete(credential) => {
      assert_eq(credential.access_token, "access")
      assert_eq(credential.refresh_token, "refresh")
    }
    _ => fail("expected a complete token response")
  }
  assert_eq(transport_impl.requests.length(), 1)
  let request = transport_impl.requests[0]
  assert_eq(request.url, config.token_endpoint)
  assert_eq(
    request.body,
    "client_id=client-id&device_code=device%2Fcode&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code",
  )
  assert_eq(header_value(request.headers, "Accept"), "application/json")
}

///|
async test "token slow down remains typed control flow" {
  let slow_down_body =
    #|{"error":"slow_down","interval":11}
  let transport_impl = RecordingOAuthTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 400, body: slow_down_body },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let config : DeviceFlowConfig = {
    client_id: "client-id",
    device_auth_endpoint: "https://auth.kimi.com/device",
    token_endpoint: "https://auth.kimi.com/token",
    scope: "ignored",
    default_headers: Map::from_array([]),
  }
  let result = poll_token(config, "device", transport)
  match result {
    PollTokenResult::SlowDown(interval) => assert_eq(interval, 11)
    _ => fail("expected slow_down control result")
  }
}

///|
async test "fractional token timing values are rejected" {
  let body =
    #|{"access_token":"access","refresh_token":"refresh","expires_in":3600.5}
  let transport_impl = RecordingOAuthTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let config : DeviceFlowConfig = {
    client_id: "client-id",
    device_auth_endpoint: "https://auth.kimi.com/device",
    token_endpoint: "https://auth.kimi.com/token",
    scope: "ignored",
    default_headers: Map::from_array([]),
  }
  match poll_token(config, "device", transport) {
    PollTokenResult::Failed(OAuthError::ParseError(detail)) =>
      assert_true(detail.contains("invalid expires_in"))
    _ => fail("fractional expires_in must fail instead of truncating")
  }
}

///|
async test "token non-success status cannot masquerade as a credential" {
  let error_status_body =
    #|{"access_token":"access","refresh_token":"refresh","expires_in":3600}
  let transport_impl = RecordingOAuthTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 500, body: error_status_body },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let config : DeviceFlowConfig = {
    client_id: "client-id",
    device_auth_endpoint: "https://auth.kimi.com/device",
    token_endpoint: "https://auth.kimi.com/token",
    scope: "ignored",
    default_headers: Map::from_array([]),
  }
  let result = poll_token(config, "device", transport)
  match result {
    PollTokenResult::Failed(OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("status=500"))
    _ => fail("expected non-success token status to remain an HTTP error")
  }
}

///|
async test "config default_headers are merged and flow headers override" {
  let success_body =
    #|{"device_code":"device","user_code":"user","verification_uri":"https://auth.kimi.com/device","verification_uri_complete":"https://auth.kimi.com/device?code=user","expires_in":900,"interval":5}
  let transport_impl = RecordingOAuthTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: success_body },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let config : DeviceFlowConfig = {
    client_id: "client-id",
    device_auth_endpoint: "https://auth.kimi.com/api/oauth/device_authorization",
    token_endpoint: "https://auth.kimi.com/api/oauth/token",
    scope: "",
    default_headers: Map::from_array([
      ("User-Agent", "kimi-code-cli/1.2.3"),
      ("X-Msh-Platform", "kimi_code_cli"),
      // A same-named default MUST be overridden by the flow's own Accept.
      ("Accept", "application/xml"),
    ]),
  }
  // request_device_code raises on transport failure; success path records
  // the request, which is all this test asserts on.
  let _ = request_device_code(config, transport)
  let request = transport_impl.requests[0]
  // Default identity headers survive the merge.
  assert_eq(header_value(request.headers, "User-Agent"), "kimi-code-cli/1.2.3")
  assert_eq(header_value(request.headers, "X-Msh-Platform"), "kimi_code_cli")
  // Flow's Accept wins over the default.
  assert_eq(header_value(request.headers, "Accept"), "application/json")
}

///|
test "canonical provider credential round trips its method tag" {
  let oauth = Credential::Credential(
    access_token="access",
    refresh_token="refresh",
    expires_at=42,
    metadata=Map([("account_id", "acct-1")]),
  )
  let value = ProviderCredential::OAuth(oauth)
  let restored = match ProviderCredential::from_json(value.to_json()) {
    Some(result) => result
    None => fail("canonical credential must deserialize")
  }
  match restored {
    ProviderCredential::OAuth(credential) => {
      assert_eq(credential.metadata_value("account_id"), Some("acct-1"))
      assert_eq(credential.access_token, "access")
    }
    _ => fail("OAuth tag must survive canonical persistence")
  }
  let api = ProviderCredential::ApiKey(
    ApiKeyCredential::ApiKeyCredential(secret="api-secret"),
  )
  match ProviderCredential::from_json(api.to_json()) {
    Some(ProviderCredential::ApiKey(credential)) =>
      assert_eq(credential.secret, "api-secret")
    _ => fail("API-key tag must survive canonical persistence")
  }
}
