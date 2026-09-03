///|
/// Wire-contract tests for the RFC 6749 §6 refresh token grant.

///|
struct RefreshPostTransport {
  requests : Array[OAuthHttpRequest]
  response : OAuthHttpResponse
}

///|
pub impl OAuthHttpTransport for RefreshPostTransport with fn post(
  self : RefreshPostTransport,
  request : OAuthHttpRequest,
) -> OAuthHttpResponse {
  self.requests.push(request)
  self.response
}

///|
pub impl OAuthHttpTransport for RefreshPostTransport with fn get(
  _self : RefreshPostTransport,
  _url : String,
  _headers : Map[String, String],
) -> OAuthHttpResponse raise OAuthError {
  raise OAuthError::HttpError("unexpected GET in refresh test")
}

///|
async test "refresh POST matches form wire contract and rotates tokens" {
  let transport_impl = RefreshPostTransport::{
    requests: [],
    response: OAuthHttpResponse::{
      status: 200,
      body: "{\"access_token\":\"new-access\",\"refresh_token\":\"rotated-token\",\"expires_in\":3600,\"token_type\":\"Bearer\"}",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_refresh_flow(
      token_endpoint="https://auth.example.com/token",
      client_id="client-id",
      refresh_token="old/secret token",
      transport~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => {
      assert_eq(credential.access_token, "new-access")
      assert_eq(credential.refresh_token, "rotated-token")
      assert_eq(credential.token_type, "Bearer")
      let now_secs = (@async.now() / 1000L).to_int()
      assert_true(
        credential.expires_at >= now_secs + 3590 &&
        credential.expires_at <= now_secs + 3610,
      )
    }
    Err(error) => fail("unexpected failure: " + Show::to_string(error))
  }
  assert_eq(transport_impl.requests.length(), 1)
  let request = transport_impl.requests[0]
  assert_eq(request.url, "https://auth.example.com/token")
  assert_eq(
    wire_header(request.headers, "Content-Type"),
    "application/x-www-form-urlencoded",
  )
  assert_eq(wire_header(request.headers, "Accept"), "application/json")
  assert_eq(
    request.body,
    "grant_type=refresh_token&refresh_token=old%2Fsecret%20token&client_id=client-id",
  )
}

///|
async test "refresh without a rotated refresh token keeps the input token" {
  let transport_impl = RefreshPostTransport::{
    requests: [],
    response: OAuthHttpResponse::{
      status: 200,
      body: "{\"access_token\":\"new-access\",\"expires_in\":60}",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_refresh_flow(
      token_endpoint="https://auth.example.com/token",
      client_id="client-id",
      refresh_token="kept-token",
      transport~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => {
      assert_eq(credential.refresh_token, "kept-token")
      assert_eq(credential.access_token, "new-access")
    }
    Err(error) => fail("unexpected failure: " + Show::to_string(error))
  }
}

///|
async test "refresh invalid_grant stays typed" {
  let transport_impl = RefreshPostTransport::{
    requests: [],
    response: OAuthHttpResponse::{
      status: 400,
      body: "{\"error\":\"invalid_grant\"}",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_refresh_flow(
      token_endpoint="https://auth.example.com/token",
      client_id="client-id",
      refresh_token="revoked",
      transport~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::InvalidGrant) => ()
    Err(error) => fail("expected InvalidGrant, got: " + Show::to_string(error))
    Ok(_) => fail("a revoked refresh token must not mint a credential")
  }
}

///|
async test "refresh unmapped OAuth error keeps status diagnostics" {
  let transport_impl = RefreshPostTransport::{
    requests: [],
    response: OAuthHttpResponse::{
      status: 400,
      body: "{\"error\":\"invalid_client\"}",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_refresh_flow(
      token_endpoint="https://auth.example.com/token",
      client_id="client-id",
      refresh_token="token",
      transport~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::HttpError(detail)) =>
      assert_true(
        detail.contains("token error=invalid_client") &&
        detail.contains("status=400"),
      )
    Err(error) =>
      fail("expected typed HTTP error, got: " + Show::to_string(error))
    Ok(_) => fail("invalid_client must not mint a credential")
  }
}

///|
async test "refresh server failure is not parsed as OAuth JSON" {
  let transport_impl = RefreshPostTransport::{
    requests: [],
    response: OAuthHttpResponse::{
      status: 502,
      body: "<html>bad gateway</html>",
    },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_refresh_flow(
      token_endpoint="https://auth.example.com/token",
      client_id="client-id",
      refresh_token="token",
      transport~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("status=502"))
    Err(error) =>
      fail("expected typed HTTP error, got: " + Show::to_string(error))
    Ok(_) => fail("a 502 must not mint a credential")
  }
  assert_eq(transport_impl.requests.length(), 1)
}

///|
async test "refresh success response missing required fields is a parse error" {
  let cases : Array[String] = [
    "{}", "{\"access_token\":\"\",\"expires_in\":60}", "{\"access_token\":\"a\"}",
    "{\"access_token\":\"a\",\"expires_in\":60.5}",
  ]
  for body in cases {
    let transport_impl = RefreshPostTransport::{
      requests: [],
      response: OAuthHttpResponse::{ status: 200, body, },
    }
    let transport : &OAuthHttpTransport = transport_impl
    let result = Ok(
      run_refresh_flow(
        token_endpoint="https://auth.example.com/token",
        client_id="client-id",
        refresh_token="token",
        transport~,
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
      Ok(_) => fail("body must not mint a credential: " + body)
    }
  }
}

///|
async test "refresh non-object success response is a parse error" {
  let transport_impl = RefreshPostTransport::{
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: "\"ok\"", },
  }
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_refresh_flow(
      token_endpoint="https://auth.example.com/token",
      client_id="client-id",
      refresh_token="token",
      transport~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::ParseError(_)) => ()
    Err(error) => fail("expected parse error, got: " + Show::to_string(error))
    Ok(_) => fail("a JSON string must not mint a credential")
  }
}
