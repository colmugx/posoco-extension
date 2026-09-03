///|
/// metadata_discovery.mbt — OAuth metadata discovery for MCP server login.
///
/// RFC 9728 protected-resource metadata points at authorization servers;
/// RFC 8414 authorization-server metadata carries the endpoint URLs the
/// device/registration/refresh flows need. Both are GETs over the injected
/// transport; callers pass the complete well-known URL.

///|
pub(all) struct ResourceMetadata {
  authorization_servers : Array[String]
}

///|
pub fn ResourceMetadata::ResourceMetadata(
  authorization_servers~ : Array[String],
) -> ResourceMetadata {
  { authorization_servers, }
}

///|
pub async fn fetch_resource_metadata(
  uri : String,
  transport : &OAuthHttpTransport,
) -> ResourceMetadata raise OAuthError {
  let headers : Map[String, String] = Map([("Accept", "application/json")])
  let response = transport.get(uri, headers)
  if response.status < 200 || response.status >= 300 {
    raise OAuthError::HttpError(
      "resource metadata HTTP status=" +
      response.status.to_string() +
      ", body_chars=" +
      response.body.length().to_string(),
    )
  }
  let json = @json.parse(response.body) catch {
    err =>
      raise OAuthError::ParseError(
        "resource metadata response: " + err.to_string(),
      )
  }
  match json {
    Json::Object(map) =>
      match map.get("authorization_servers") {
        Some(Json::Array(items)) => {
          let servers : Array[String] = []
          for item in items {
            match item {
              Json::String(server) =>
                if server.length() > 0 {
                  servers.push(server)
                } else {
                  raise OAuthError::ParseError(
                    "empty entry in authorization_servers",
                  )
                }
              _ =>
                raise OAuthError::ParseError(
                  "non-string entry in authorization_servers",
                )
            }
          }
          if servers.length() == 0 {
            raise OAuthError::ParseError(
              "empty authorization_servers in resource metadata",
            )
          }
          ResourceMetadata::ResourceMetadata(authorization_servers=servers)
        }
        _ =>
          raise OAuthError::ParseError(
            "missing authorization_servers array in resource metadata",
          )
      }
    _ =>
      raise OAuthError::ParseError(
        "resource metadata response is not an object",
      )
  }
}

///|
pub(all) struct ServerMetadata {
  authorization_endpoint : String
  token_endpoint : String
  device_authorization_endpoint : String?
  registration_endpoint : String?
  scopes_supported : Array[String]
}

///|
pub fn ServerMetadata::ServerMetadata(
  authorization_endpoint~ : String,
  token_endpoint~ : String,
  device_authorization_endpoint? : String,
  registration_endpoint? : String,
  scopes_supported? : Array[String] = [],
) -> ServerMetadata {
  {
    authorization_endpoint,
    token_endpoint,
    device_authorization_endpoint,
    registration_endpoint,
    scopes_supported,
  }
}

///|
pub async fn fetch_server_metadata(
  metadata_url : String,
  transport : &OAuthHttpTransport,
) -> ServerMetadata raise OAuthError {
  let headers : Map[String, String] = Map([("Accept", "application/json")])
  let response = transport.get(metadata_url, headers)
  if response.status < 200 || response.status >= 300 {
    raise OAuthError::HttpError(
      "server metadata HTTP status=" +
      response.status.to_string() +
      ", body_chars=" +
      response.body.length().to_string(),
    )
  }
  let json = @json.parse(response.body) catch {
    err =>
      raise OAuthError::ParseError(
        "server metadata response: " + err.to_string(),
      )
  }
  match json {
    Json::Object(map) => {
      let authorization_endpoint = match map.get("authorization_endpoint") {
        Some(Json::String(s)) if s.length() > 0 => s
        _ =>
          raise OAuthError::ParseError(
            "missing authorization_endpoint in server metadata",
          )
      }
      let token_endpoint = match map.get("token_endpoint") {
        Some(Json::String(s)) if s.length() > 0 => s
        _ =>
          raise OAuthError::ParseError(
            "missing token_endpoint in server metadata",
          )
      }
      // Optional endpoint fields: present-and-non-empty wins, anything else
      // (missing, empty, wrong type) degrades to None.
      let device_authorization_endpoint : String? = match
        map.get("device_authorization_endpoint") {
        Some(Json::String(s)) if s.length() > 0 => Some(s)
        _ => None
      }
      let registration_endpoint : String? = match
        map.get("registration_endpoint") {
        Some(Json::String(s)) if s.length() > 0 => Some(s)
        _ => None
      }
      let scopes_supported : Array[String] = match map.get("scopes_supported") {
        Some(Json::Array(items)) => {
          let scopes : Array[String] = []
          for item in items {
            match item {
              Json::String(scope) => scopes.push(scope)
              _ => ()
            }
          }
          scopes
        }
        _ => []
      }
      ServerMetadata::{
        authorization_endpoint,
        token_endpoint,
        device_authorization_endpoint,
        registration_endpoint,
        scopes_supported,
      }
    }
    _ =>
      raise OAuthError::ParseError("server metadata response is not an object")
  }
}
