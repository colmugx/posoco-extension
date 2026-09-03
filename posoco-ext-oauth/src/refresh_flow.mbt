///|
/// refresh_flow.mbt — RFC 6749 §6 refresh token grant.
///
/// MCP server credentials refresh at the authorization server's token
/// endpoint; the wire contract mirrors the device-flow token poll, but a
/// server that does not rotate refresh tokens keeps the caller's token.

///|
pub async fn run_refresh_flow(
  token_endpoint~ : String,
  client_id~ : String,
  refresh_token~ : String,
  transport~ : &OAuthHttpTransport,
) -> Credential raise OAuthError {
  let headers : Map[String, String] = Map([
    ("Content-Type", "application/x-www-form-urlencoded"),
    ("Accept", "application/json"),
  ])
  let body = "grant_type=" +
    oauth_form_url_encode("refresh_token") +
    "&refresh_token=" +
    oauth_form_url_encode(refresh_token) +
    "&client_id=" +
    oauth_form_url_encode(client_id)
  let response = transport.post(OAuthHttpRequest::{
    url: token_endpoint,
    body,
    headers,
  })
  // Server failures are terminal. Do not parse an arbitrary HTML/proxy body
  // as OAuth JSON; preserve only safe diagnostics.
  if response.status >= 500 {
    raise OAuthError::HttpError(
      "token HTTP status=" +
      response.status.to_string() +
      ", body_chars=" +
      response.body.length().to_string(),
    )
  }
  let json = @json.parse(response.body) catch {
    err =>
      raise OAuthError::ParseError("refresh token response: " + err.to_string())
  }
  match json {
    Json::Object(map) =>
      match map.get("error") {
        Some(Json::String(err_code)) =>
          match err_code {
            "invalid_grant" => raise InvalidGrant
            "access_denied" => raise AccessDenied
            "expired_token" => raise ExpiredToken
            other =>
              raise OAuthError::HttpError(
                "token error=" +
                other +
                ", status=" +
                response.status.to_string(),
              )
          }
        _ => {
          if response.status < 200 || response.status >= 300 {
            raise OAuthError::HttpError(
              "token HTTP status=" + response.status.to_string(),
            )
          }
          parse_refresh_success(map, refresh_token)
        }
      }
    _ => raise OAuthError::ParseError("refresh token response is not an object")
  }
}

///|
/// Success-path parse shaped like the device-flow token poll. A rotating
/// server returns a new refresh_token; otherwise the input token carries
/// over into the refreshed credential.
fn parse_refresh_success(
  map : Map[String, Json],
  input_refresh_token : String,
) -> Credential raise OAuthError {
  let access_token = match map.get("access_token") {
    Some(Json::String(s)) if s.length() > 0 => s
    _ =>
      raise OAuthError::ParseError("missing access_token in success response")
  }
  let refresh_token = match map.get("refresh_token") {
    Some(Json::String(s)) if s.length() > 0 => s
    _ => input_refresh_token
  }
  let expires_in = match map.get("expires_in") {
    Some(Json::Number(n, ..)) =>
      match parse_positive_integer(n) {
        Some(value) => value
        None =>
          raise OAuthError::ParseError("invalid expires_in in success response")
      }
    _ => raise OAuthError::ParseError("missing expires_in in success response")
  }
  let token_type = match map.get("token_type") {
    Some(Json::String(s)) => if s.length() > 0 { s } else { "Bearer" }
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
