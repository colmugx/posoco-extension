///|
/// Regression: RFC 8628 interval is seconds, and the poll loop must sleep
/// interval*1000ms — treating it as milliseconds hammered the token endpoint
/// ~interval×100 times per second until device-code expiry. This file is not
/// target-gated so the timing contract holds on native and js.

///|
struct TimedPollTransport {
  responses : Array[OAuthHttpResponse]
  mut next : Int
  post_times : Array[Int64]
}

///|
pub impl OAuthHttpTransport for TimedPollTransport with fn post(
  self : TimedPollTransport,
  _request : OAuthHttpRequest,
) -> OAuthHttpResponse raise OAuthError {
  if self.next >= self.responses.length() {
    raise OAuthError::HttpError("no queued response left in test transport")
  }
  let response = self.responses[self.next]
  self.next += 1
  self.post_times.push(@async.now())
  response
}

///|
async test "device flow sleeps interval seconds between polls" {
  let device_auth_body =
    #|{"device_code":"device","user_code":"user","verification_uri":"https://auth.example.com/device","verification_uri_complete":"https://auth.example.com/device?code=user","expires_in":900,"interval":1}
  let pending_body =
    #|{"error":"authorization_pending"}
  let token_body =
    #|{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer"}
  let transport_impl = TimedPollTransport::{
    responses: [
      OAuthHttpResponse::{ status: 200, body: device_auth_body, },
      // First poll is pending, so the loop must sleep a full second again
      // before the poll that completes.
      OAuthHttpResponse::{ status: 400, body: pending_body, },
      OAuthHttpResponse::{ status: 200, body: token_body, },
    ],
    next: 0,
    post_times: [],
  }
  let transport : &OAuthHttpTransport = transport_impl
  let interaction_impl = NoopAuthInteraction::NoopAuthInteraction()
  let interaction : &AuthInteraction = interaction_impl
  let config : DeviceFlowConfig = {
    client_id: "client-id",
    device_auth_endpoint: "https://auth.example.com/device",
    token_endpoint: "https://auth.example.com/token",
    scope: "",
    default_headers: Map::from_array([]),
  }
  let result = Ok(
    run_device_flow_with_transport(config, interaction, transport),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => {
      assert_eq(credential.access_token, "access")
      assert_eq(credential.refresh_token, "refresh")
    }
    Err(error) => fail("unexpected failure: " + Show::to_string(error))
  }
  // Posts: device-code request, then two token polls.
  assert_eq(transport_impl.post_times.length(), 3)
  // Each inter-poll gap is one interval=1s sleep, converted to 1000ms.
  let first_gap = transport_impl.post_times[1] - transport_impl.post_times[0]
  let second_gap = transport_impl.post_times[2] - transport_impl.post_times[1]
  assert_true(first_gap >= 1000L && first_gap < 1500L)
  assert_true(second_gap >= 1000L && second_gap < 1500L)
}
