///|
/// Wire-contract tests for RFC 7591 dynamic client registration.

///|
struct RegistrationPostTransport {
  requests : Array[OAuthHttpRequest]
  response : OAuthHttpResponse
}

///|
pub impl OAuthHttpTransport for RegistrationPostTransport with fn post(
  self : RegistrationPostTransport,
  request : OAuthHttpRequest,
) -> OAuthHttpResponse {
  self.requests.push(request)
  self.response
}

///|
pub impl OAuthHttpTransport for RegistrationPostTransport with fn get(
  _self : RegistrationPostTransport,
  _url : String,
  _headers : Map[String, String],
) -> OAuthHttpResponse raise OAuthError {
  raise OAuthError::HttpError("unexpected GET in registration test")
}

///|
async test "registration POST matches RFC 7591 JSON wire contract" {
  let transport_impl = RegistrationPostTransport::{
    requests: [],
    response: OAuthHttpResponse::{
      status: 201,
      body: "{\"client_id\":\"registered-client\",\"client_secret\":\"s\"}",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    register_client(
      "https://auth.example.com/register", "Posoco MCP", transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(client_id) => assert_eq(client_id, "registered-client")
    Err(error) => fail("unexpected failure: " + Show::to_string(error))
  }
  assert_eq(transport_impl.requests.length(), 1)
  let request = transport_impl.requests[0]
  assert_eq(request.url, "https://auth.example.com/register")
  assert_eq(wire_header(request.headers, "Content-Type"), "application/json")
  assert_eq(wire_header(request.headers, "Accept"), "application/json")
  assert_eq(
    request.body,
    "{\"client_name\":\"Posoco MCP\",\"grant_types\":[\"urn:ietf:params:oauth:grant-type:device_code\",\"authorization_code\"]}",
  )
}

///|
async test "registration non-2xx stays a typed HttpError" {
  let transport_impl = RegistrationPostTransport::{
    requests: [],
    response: OAuthHttpResponse::{
      status: 400,
      body: "{\"error\":\"invalid_client_metadata\"}",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    register_client(
      "https://auth.example.com/register", "Posoco MCP", transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("status=400"))
    Err(error) =>
      fail("expected typed HTTP error, got: " + Show::to_string(error))
    Ok(_) => fail("a 400 must not yield a client_id")
  }
}

///|
async test "registration response without usable client_id is a parse error" {
  let cases : Array[String] = [
    "{}", "{\"client_id\":\"\"}", "{\"client_id\":42}",
  ]
  for body in cases {
    let transport_impl = RegistrationPostTransport::{
      requests: [],
      response: OAuthHttpResponse::{ status: 200, body, },
    }
    let transport : &OAuthHttpTransport = transport_impl
    let result = Ok(
      register_client(
        "https://auth.example.com/register", "Posoco MCP", transport,
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
      Ok(_) => fail("body must not yield a client_id: " + body)
    }
  }
}

///|
async test "registration non-object response is a parse error" {
  let transport_impl = RegistrationPostTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: "[\"client_id\"]", },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    register_client(
      "https://auth.example.com/register", "Posoco MCP", transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::ParseError(_)) => ()
    Err(error) => fail("expected parse error, got: " + Show::to_string(error))
    Ok(_) => fail("a JSON array must not yield a client_id")
  }
}
