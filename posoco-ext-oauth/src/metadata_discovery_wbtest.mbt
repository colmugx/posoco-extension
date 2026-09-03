///|
/// Wire-contract tests for metadata discovery and the transport GET seam.
/// Fakes are defined per-file with unique names so they compile on every
/// target (device_flow_wbtest.mbt is native-gated and cannot be referenced).

///|
struct MetadataGetTransport {
  get_urls : Array[String]
  get_headers : Array[Map[String, String]]
  response : OAuthHttpResponse
}

///|
pub impl OAuthHttpTransport for MetadataGetTransport with fn post(
  _self : MetadataGetTransport,
  _request : OAuthHttpRequest,
) -> OAuthHttpResponse raise OAuthError {
  raise OAuthError::HttpError("unexpected POST in metadata discovery test")
}

///|
pub impl OAuthHttpTransport for MetadataGetTransport with fn get(
  self : MetadataGetTransport,
  url : String,
  headers : Map[String, String],
) -> OAuthHttpResponse {
  self.get_urls.push(url)
  self.get_headers.push(headers)
  self.response
}

///|
struct PostOnlyTransport {
  response : OAuthHttpResponse
}

///|
pub impl OAuthHttpTransport for PostOnlyTransport with fn post(
  self : PostOnlyTransport,
  _request : OAuthHttpRequest,
) -> OAuthHttpResponse {
  self.response
}

///|
fn wire_header(headers : Map[String, String], key : String) -> String raise {
  match headers.get(key) {
    Some(value) => value
    None => fail("missing header: " + key)
  }
}

///|
async test "resource metadata GET wire contract and parse" {
  let transport_impl = MetadataGetTransport::{
    get_urls: [],
    get_headers: [],
    response: OAuthHttpResponse::{
      status: 200,
      body: "{\"authorization_servers\":[\"https://auth.example.com\",\"https://auth2.example.com\"]}",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    fetch_resource_metadata(
      "https://mcp.example.com/.well-known/oauth-protected-resource", transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(metadata) => {
      assert_eq(metadata.authorization_servers.length(), 2)
      assert_eq(metadata.authorization_servers[0], "https://auth.example.com")
      assert_eq(metadata.authorization_servers[1], "https://auth2.example.com")
    }
    Err(error) => fail("unexpected failure: " + Show::to_string(error))
  }
  assert_eq(transport_impl.get_urls.length(), 1)
  assert_eq(
    transport_impl.get_urls[0],
    "https://mcp.example.com/.well-known/oauth-protected-resource",
  )
  assert_eq(
    wire_header(transport_impl.get_headers[0], "Accept"),
    "application/json",
  )
}

///|
async test "resource metadata non-200 stays a typed HttpError" {
  let transport_impl = MetadataGetTransport::{
    get_urls: [],
    get_headers: [],
    response: OAuthHttpResponse::{
      status: 404,
      body: "<html>not found</html>",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    fetch_resource_metadata(
      "https://mcp.example.com/.well-known/nope", transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("status=404"))
    Err(error) =>
      fail("expected typed HTTP error, got: " + Show::to_string(error))
    Ok(_) => fail("a 404 must not parse as resource metadata")
  }
  assert_eq(transport_impl.get_urls.length(), 1)
}

///|
async test "resource metadata rejects missing empty and malformed servers" {
  let cases : Array[String] = [
    "{}", "{\"authorization_servers\":[]}", "{\"authorization_servers\":[\"\"]}",
    "{\"authorization_servers\":[42]}", "{\"authorization_servers\":\"https://auth.example.com\"}",
  ]
  for body in cases {
    let transport_impl = MetadataGetTransport::{
      get_urls: [],
      get_headers: [],
      response: OAuthHttpResponse::{ status: 200, body, },
    }
    let transport : &OAuthHttpTransport = transport_impl
    let result = Ok(
      fetch_resource_metadata(
        "https://mcp.example.com/.well-known/meta", transport,
      ),
    ) catch {
      error => Err(error)
    }
    match result {
      Err(OAuthError::ParseError(_)) => ()
      Err(error) =>
        fail(
          "expected parse error for body=" +
          body +
          ", got: " +
          Show::to_string(error),
        )
      Ok(_) => fail("body must not parse as resource metadata: " + body)
    }
  }
}

///|
async test "resource metadata malformed JSON is a parse error" {
  let transport_impl = MetadataGetTransport::{
    get_urls: [],
    get_headers: [],
    response: OAuthHttpResponse::{ status: 200, body: "{not json", },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    fetch_resource_metadata(
      "https://mcp.example.com/.well-known/meta", transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::ParseError(_)) => ()
    Err(error) => fail("expected parse error, got: " + Show::to_string(error))
    Ok(_) => fail("malformed JSON must not parse")
  }
}

///|
async test "server metadata GET wire contract and full parse" {
  let transport_impl = MetadataGetTransport::{
    get_urls: [],
    get_headers: [],
    response: OAuthHttpResponse::{
      status: 200,
      body: "{\"authorization_endpoint\":\"https://auth.example.com/authorize\",\"token_endpoint\":\"https://auth.example.com/token\",\"device_authorization_endpoint\":\"https://auth.example.com/device\",\"registration_endpoint\":\"https://auth.example.com/register\",\"scopes_supported\":[\"mcp:read\",\"mcp:write\"]}",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    fetch_server_metadata(
      "https://auth.example.com/.well-known/oauth-authorization-server", transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(metadata) => {
      assert_eq(
        metadata.authorization_endpoint,
        "https://auth.example.com/authorize",
      )
      assert_eq(metadata.token_endpoint, "https://auth.example.com/token")
      assert_eq(
        metadata.device_authorization_endpoint,
        Some("https://auth.example.com/device"),
      )
      assert_eq(
        metadata.registration_endpoint,
        Some("https://auth.example.com/register"),
      )
      assert_eq(metadata.scopes_supported.length(), 2)
      assert_eq(metadata.scopes_supported[0], "mcp:read")
      assert_eq(metadata.scopes_supported[1], "mcp:write")
    }
    Err(error) => fail("unexpected failure: " + Show::to_string(error))
  }
  assert_eq(transport_impl.get_urls.length(), 1)
  assert_eq(
    transport_impl.get_urls[0],
    "https://auth.example.com/.well-known/oauth-authorization-server",
  )
  assert_eq(
    wire_header(transport_impl.get_headers[0], "Accept"),
    "application/json",
  )
}

///|
async test "server metadata optional fields default when absent" {
  let transport_impl = MetadataGetTransport::{
    get_urls: [],
    get_headers: [],
    response: OAuthHttpResponse::{
      status: 200,
      body: "{\"authorization_endpoint\":\"https://auth.example.com/authorize\",\"token_endpoint\":\"https://auth.example.com/token\"}",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    fetch_server_metadata(
      "https://auth.example.com/.well-known/meta", transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(metadata) => {
      assert_eq(metadata.device_authorization_endpoint, None)
      assert_eq(metadata.registration_endpoint, None)
      assert_eq(metadata.scopes_supported.length(), 0)
    }
    Err(error) => fail("unexpected failure: " + Show::to_string(error))
  }
}

///|
async test "server metadata missing required endpoint is a parse error" {
  let cases : Array[String] = [
    "{\"token_endpoint\":\"https://auth.example.com/token\"}", "{\"authorization_endpoint\":\"https://auth.example.com/authorize\"}",
    "{\"authorization_endpoint\":\"\",\"token_endpoint\":\"https://auth.example.com/token\"}",
  ]
  for body in cases {
    let transport_impl = MetadataGetTransport::{
      get_urls: [],
      get_headers: [],
      response: OAuthHttpResponse::{ status: 200, body, },
    }
    let transport : &OAuthHttpTransport = transport_impl
    let result = Ok(
      fetch_server_metadata(
        "https://auth.example.com/.well-known/meta", transport,
      ),
    ) catch {
      error => Err(error)
    }
    match result {
      Err(OAuthError::ParseError(detail)) =>
        assert_true(detail.contains("missing"))
      Err(error) =>
        fail(
          "expected parse error for body=" +
          body +
          ", got: " +
          Show::to_string(error),
        )
      Ok(_) => fail("incomplete server metadata must not parse: " + body)
    }
  }
}

///|
async test "server metadata non-200 stays a typed HttpError" {
  let transport_impl = MetadataGetTransport::{
    get_urls: [],
    get_headers: [],
    response: OAuthHttpResponse::{ status: 503, body: "unavailable", },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    fetch_server_metadata(
      "https://auth.example.com/.well-known/meta", transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("status=503"))
    Err(error) =>
      fail("expected typed HTTP error, got: " + Show::to_string(error))
    Ok(_) => fail("a 503 must not parse as server metadata")
  }
}

///|
async test "transport default GET fails closed for post-only impls" {
  let transport_impl = PostOnlyTransport::{
    response: OAuthHttpResponse::{ status: 200, body: "{}", },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    transport.get(
      "https://mcp.example.com/.well-known/oauth-protected-resource",
      Map::from_array([]),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("GET not supported"))
    Err(error) =>
      fail(
        "expected typed GET-unsupported error, got: " + Show::to_string(error),
      )
    Ok(_) => fail("the default GET must fail closed")
  }
}
