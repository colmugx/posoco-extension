///|
/// dynamic_registration.mbt — RFC 7591 dynamic client registration.
///
/// MCP server login registers a public client at the authorization server's
/// registration endpoint, requesting exactly the grant types the following
/// device/authorization-code flows use.

///|
pub async fn register_client(
  registration_endpoint : String,
  client_name : String,
  transport : &OAuthHttpTransport,
) -> String raise OAuthError {
  let headers : Map[String, String] = Map([
    ("Content-Type", "application/json"),
    ("Accept", "application/json"),
  ])
  let body = Json::object(
    Map([
      ("client_name", Json::string(client_name)),
      (
        "grant_types",
        Json::array([
          Json::string("urn:ietf:params:oauth:grant-type:device_code"),
          Json::string("authorization_code"),
        ]),
      ),
    ]),
  ).stringify()
  let response = transport.post(OAuthHttpRequest::{
    url: registration_endpoint,
    body,
    headers,
  })
  if response.status < 200 || response.status >= 300 {
    raise OAuthError::HttpError(
      "client registration HTTP status=" +
      response.status.to_string() +
      ", body_chars=" +
      response.body.length().to_string(),
    )
  }
  let json = @json.parse(response.body) catch {
    err =>
      raise OAuthError::ParseError(
        "client registration response: " + err.to_string(),
      )
  }
  match json {
    Json::Object(map) =>
      match map.get("client_id") {
        Some(Json::String(client_id)) if client_id.length() > 0 => client_id
        _ =>
          raise OAuthError::ParseError(
            "missing client_id in registration response",
          )
      }
    _ =>
      raise OAuthError::ParseError(
        "client registration response is not an object",
      )
  }
}
