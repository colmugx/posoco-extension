///|
/// browser_flow_wbtest.mbt — wire + behavior tests for run_pkce_browser_flow.

///|
struct RecordingAuthInteraction {
  messages : Array[AuthMessage]
  mut last_auth_url : String
}

///|
fn RecordingAuthInteraction::new() -> RecordingAuthInteraction {
  { messages: [], last_auth_url: "", }
}

///|
pub impl AuthInteraction for RecordingAuthInteraction with fn notify(
  self : RecordingAuthInteraction,
  message : AuthMessage,
) -> Unit {
  match message {
    AuthUrl(url) => self.last_auth_url = url
    _ => ()
  }
  self.messages.push(message)
}

///|
pub impl AuthInteraction for RecordingAuthInteraction with fn is_cancelled(
  _self : RecordingAuthInteraction,
) -> Bool {
  false
}

///|
/// Sleep that surfaces race cancellation as a typed Cancelled. Swallowing the
/// cancellation error itself would let a cancelled loser task run to
/// completion and overwrite the winner recorded by @async.any.
async fn sleep_ms(ms : Int) -> Unit raise OAuthError {
  @async.sleep(ms) catch {
    _ => if @async.is_being_cancelled() { raise OAuthError::Cancelled }
  }
}

///|
/// Fake callback server. Modes: fixed `delivered` pair; echo mode (reflects
/// the state from the notified authorize URL with `delivered_code`); blocking
/// until stopped (lets the paste path win); immediate raise.
struct FakeCallbackServer {
  fail_ports : Array[Int]
  started_ports : Array[Int]
  interaction : RecordingAuthInteraction
  delivered : (String, String)?
  delivered_code : String
  block_until_stopped : Bool
  raise_immediately : Bool
  wait_delay_ms : Int
  mut stop_count : Int
}

///|
pub impl CallbackServer for FakeCallbackServer with fn start(
  self : FakeCallbackServer,
  port : Int,
) -> Unit raise OAuthError {
  self.started_ports.push(port)
  for p in self.fail_ports {
    if p == port {
      raise OAuthError::HttpError("bind failed on port " + port.to_string())
    }
  }
}

///|
pub impl CallbackServer for FakeCallbackServer with fn wait_callback(
  self : FakeCallbackServer,
) -> (String, String) raise OAuthError {
  if self.raise_immediately {
    raise OAuthError::ExpiredToken
  }
  if self.wait_delay_ms > 0 {
    sleep_ms(self.wait_delay_ms)
  }
  match self.delivered {
    Some(pair) => return pair
    None => ()
  }
  if self.block_until_stopped {
    while true {
      if self.stop_count > 0 {
        raise OAuthError::HttpError("server stopped before callback")
      }
      sleep_ms(5)
    }
    abort("unreachable")
  }
  // Echo mode: reflect the state from the notified authorize URL.
  let state = match
    extract_query_param(self.interaction.last_auth_url, "state") {
    Some(s) => s
    None => ""
  }
  (self.delivered_code, state)
}

///|
pub impl CallbackServer for FakeCallbackServer with fn stop(
  self : FakeCallbackServer,
) -> Unit {
  self.stop_count += 1
}

///|
/// Fake prompt. Modes: fixed scripted inputs; or echo mode which returns the
/// authorize URL extracted from the prompt message with `&code=` appended
/// (a pasteable callback URL carrying the flow's real state).
struct ScriptedPromptInteraction {
  inputs : Array[String]
  echo_url_code : String
  delay_ms : Int
  mut index : Int
}

///|
pub impl AuthPromptInteraction for ScriptedPromptInteraction with fn prompt(
  self : ScriptedPromptInteraction,
  request : AuthPromptRequest,
) -> String raise OAuthError {
  if self.delay_ms > 0 {
    sleep_ms(self.delay_ms)
  }
  if self.echo_url_code.length() > 0 {
    let message = match request {
      AuthPromptRequest::Secret(message~) => message
      AuthPromptRequest::Select(message~, ..) => message
    }
    let url = match message.find("https://") {
      Some(pos) => message.sub(start=pos).to_owned()
      None => message
    }
    return url + "&code=" + self.echo_url_code
  }
  if self.index < self.inputs.length() {
    let value = self.inputs[self.index]
    self.index += 1
    value
  } else {
    raise OAuthError::Cancelled
  }
}

///|
struct BrowserFlowTransport {
  requests : Array[OAuthHttpRequest]
  response : OAuthHttpResponse
  fail : Bool
}

///|
pub impl OAuthHttpTransport for BrowserFlowTransport with fn post(
  self : BrowserFlowTransport,
  request : OAuthHttpRequest,
) -> OAuthHttpResponse raise OAuthError {
  self.requests.push(request)
  if self.fail {
    raise OAuthError::HttpError("network down")
  }
  self.response
}

///|
fn flow_config(
  extra : Array[(String, String)],
  fallback : Int?,
) -> PkceFlowConfig {
  {
    client_id: "client-id",
    authorize_url: "https://auth.example.com/authorize",
    token_url: "https://auth.example.com/token",
    redirect_uri: "http://localhost:1455/auth/callback",
    callback_port: 1455,
    scope: "openid profile",
    extra_authorize_params: extra,
    fallback_port: fallback,
  }
}

///|
const TOKEN_BODY : String =
  #|{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer"}

///|
test "authorize URL carries state, extras, and url encoding" {
  let config = flow_config(
    [("originator", "posoco test"), ("prompt", "consent")],
    None,
  )
  let pkce : PkcePair = {
    code_verifier: "v",
    code_challenge: "challenge",
    code_challenge_method: "S256",
  }
  let url = build_authorize_url(
    config, pkce, "st ate+value", "http://localhost:1455/auth/callback",
  )
  assert_true(
    url.has_prefix(
      "https://auth.example.com/authorize?response_type=code&client_id=client-id",
    ),
  )
  assert_true(
    url.contains("redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"),
  )
  assert_true(url.contains("scope=openid%20profile"))
  assert_true(
    url.contains("code_challenge=challenge&code_challenge_method=S256"),
  )
  assert_true(url.contains("&state=st%20ate%2Bvalue"))
  assert_true(url.contains("&originator=posoco%20test"))
  assert_true(url.contains("&prompt=consent"))
}

///|
test "extract_query_param handles both orders and decoys" {
  assert_eq(extract_query_param("/cb?code=abc&state=xyz", "code"), Some("abc"))
  assert_eq(extract_query_param("/cb?code=abc&state=xyz", "state"), Some("xyz"))
  assert_eq(extract_query_param("/cb?state=xyz&code=abc", "code"), Some("abc"))
  assert_eq(extract_query_param("/cb?state=xyz&code=abc", "state"), Some("xyz"))
  assert_eq(extract_query_param("/cb?x_code=1&code=abc", "code"), Some("abc"))
  assert_eq(extract_query_param("/cb?code=abc", "state"), None)
  assert_eq(extract_query_param("/cb?other=1", "code"), None)
}

///|
test "paste parser accepts full URL and bare query, rejects bare code" {
  assert_eq(
    parse_pasted_authorization(
      "http://localhost:1455/auth/callback?code=abc&state=xyz",
    ),
    Some(("abc", "xyz")),
  )
  assert_eq(
    parse_pasted_authorization("code=abc&state=xyz"),
    Some(("abc", "xyz")),
  )
  assert_eq(
    parse_pasted_authorization(
      "  https://auth.example.com/authorize?state=xyz&code=abc  ",
    ),
    Some(("abc", "xyz")),
  )
  assert_eq(parse_pasted_authorization("just-a-bare-code"), None)
  assert_eq(parse_pasted_authorization("code=abc"), None)
  assert_eq(parse_pasted_authorization("code=&state=xyz"), None)
}

///|
test "oauth_random_bytes returns the requested length and varies" {
  assert_eq(oauth_random_bytes(0).length(), 0)
  let first = oauth_random_bytes(48)
  let second = oauth_random_bytes(48)
  assert_eq(first.length(), 48)
  assert_eq(second.length(), 48)
  assert_true(first != second)
}

///|
test "generate_state is 22 base64url chars and varies" {
  let first = generate_state()
  let second = generate_state()
  assert_eq(first.length(), 22)
  assert_true(first != second)
  for ch in first {
    let ok = (ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '-' ||
      ch == '_'
    assert_true(ok)
  }
}

///|
test "generate_pkce verifier is 64 RFC 7636 chars with matching challenge" {
  let pkce = generate_pkce()
  assert_eq(pkce.code_verifier.length(), 64)
  assert_eq(pkce.code_challenge.length(), 43)
  assert_eq(pkce.code_challenge_method, "S256")
  for ch in pkce.code_verifier {
    let ok = (ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '-' ||
      ch == '_' ||
      ch == '.' ||
      ch == '~'
    assert_true(ok)
  }
}

///|
async test "happy path: state round-trips, default parser, server stopped" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "the_code",
    block_until_stopped: false,
    raise_immediately: false,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_pkce_browser_flow(flow_config([], None), interaction, server, transport),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => {
      assert_eq(credential.access_token, "access")
      assert_eq(credential.refresh_token, "refresh")
      assert_eq(credential.token_type, "Bearer")
    }
    Err(error) => fail("unexpected flow failure: " + Show::to_string(error))
  }
  // The notified URL carried a real state, echoed back by the fake server.
  let auth_url = interaction.last_auth_url
  match extract_query_param(auth_url, "state") {
    Some(state) => assert_eq(state.length(), 22)
    None => fail("authorize URL must carry state")
  }
  assert_eq(transport_impl.requests.length(), 1)
  let request = transport_impl.requests[0]
  assert_eq(request.url, "https://auth.example.com/token")
  assert_true(
    request.body.has_prefix(
      "grant_type=authorization_code&client_id=client-id&code=the_code&code_verifier=",
    ),
  )
  assert_true(
    request.body.contains(
      "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
    ),
  )
  assert_eq(server_impl.started_ports, [1455])
  assert_eq(server_impl.stop_count, 1)
}

///|
async test "state mismatch raises typed parse error and stops the server" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: Some(("the_code", "forged-state")),
    delivered_code: "the_code",
    block_until_stopped: false,
    raise_immediately: false,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_pkce_browser_flow(flow_config([], None), interaction, server, transport),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::ParseError(detail)) =>
      assert_eq(detail, "oauth state mismatch")
    Err(error) =>
      fail("expected state mismatch, got: " + Show::to_string(error))
    Ok(_) => fail("a forged state must not mint a credential")
  }
  assert_eq(transport_impl.requests.length(), 0)
  assert_eq(server_impl.stop_count, 1)
}

///|
async test "fallback port rewrites redirect_uri in authorize URL and exchange" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [1455],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "the_code",
    block_until_stopped: false,
    raise_immediately: false,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_pkce_browser_flow(
      flow_config([], Some(1457)),
      interaction,
      server,
      transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => assert_eq(credential.access_token, "access")
    Err(error) => fail("unexpected flow failure: " + Show::to_string(error))
  }
  assert_eq(server_impl.started_ports, [1455, 1457])
  assert_true(
    interaction.last_auth_url.contains(
      "redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback",
    ),
  )
  assert_true(
    transport_impl.requests[0].body.contains(
      "&redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback",
    ),
  )
}

///|
async test "both ports failing raises the primary bind error" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [1455, 1457],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "the_code",
    block_until_stopped: false,
    raise_immediately: false,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_pkce_browser_flow(
      flow_config([], Some(1457)),
      interaction,
      server,
      transport,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("bind failed on port 1455"))
    Err(error) => fail("expected bind error, got: " + Show::to_string(error))
    Ok(_) => fail("both binds failing must not mint a credential")
  }
  assert_eq(server_impl.started_ports, [1455, 1457])
  assert_eq(interaction.messages.length(), 0)
}

///|
async test "custom parse_credential hook replaces the lenient default" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "the_code",
    block_until_stopped: false,
    raise_immediately: false,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_pkce_browser_flow(
      flow_config([], None),
      interaction,
      server,
      transport,
      parse_credential=fn(json : Json) -> Credential raise OAuthError {
        let base = parse_token_response(json)
        Credential::Credential(
          access_token="custom-parsed:" + base.access_token,
          refresh_token=base.refresh_token,
          expires_at=base.expires_at,
          token_type=base.token_type,
        )
      },
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => assert_eq(credential.access_token, "custom-parsed:access")
    Err(error) => fail("unexpected flow failure: " + Show::to_string(error))
  }
}

///|
async test "default parser stays lenient on missing optional fields" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "the_code",
    block_until_stopped: false,
    raise_immediately: false,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{
      status: 200,
      body: "{\"access_token\":\"bare\"}",
    },
    fail: false,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_pkce_browser_flow(flow_config([], None), interaction, server, transport),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => {
      assert_eq(credential.access_token, "bare")
      assert_eq(credential.refresh_token, "")
      assert_eq(credential.token_type, "Bearer")
      let now_secs = (@async.now() / 1000L).to_int()
      assert_true(
        credential.expires_at >= now_secs + 3590 &&
        credential.expires_at <= now_secs + 3610,
      )
    }
    Err(error) => fail("unexpected flow failure: " + Show::to_string(error))
  }
}

///|
async test "transport failure after start still stops the server" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "the_code",
    block_until_stopped: false,
    raise_immediately: false,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: true,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let result = Ok(
    run_pkce_browser_flow(flow_config([], None), interaction, server, transport),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::HttpError(detail)) =>
      assert_true(detail.contains("network down"))
    Err(error) =>
      fail("expected transport error, got: " + Show::to_string(error))
    Ok(_) => fail("a failed exchange must not mint a credential")
  }
  assert_eq(server_impl.stop_count, 1)
}

///|
async test "paste wins the race against a silent server" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "",
    block_until_stopped: true,
    raise_immediately: false,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let prompt_impl : ScriptedPromptInteraction = {
    inputs: [],
    echo_url_code: "pasted_code",
    delay_ms: 0,
    index: 0,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let prompt : &AuthPromptInteraction = prompt_impl
  let result = Ok(
    run_pkce_browser_flow(
      flow_config([], None),
      interaction,
      server,
      transport,
      prompt~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => assert_eq(credential.access_token, "access")
    Err(error) => fail("paste path failed: " + Show::to_string(error))
  }
  assert_true(
    transport_impl.requests[0].body.contains("&code=pasted_code&code_verifier="),
  )
  assert_true(server_impl.stop_count >= 1)
}

///|
async test "pasted state is validated" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "",
    block_until_stopped: true,
    raise_immediately: false,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let prompt_impl : ScriptedPromptInteraction = {
    inputs: ["code=pasted_code&state=forged-state"],
    echo_url_code: "",
    delay_ms: 0,
    index: 0,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let prompt : &AuthPromptInteraction = prompt_impl
  let result = Ok(
    run_pkce_browser_flow(
      flow_config([], None),
      interaction,
      server,
      transport,
      prompt~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OAuthError::ParseError(detail)) =>
      assert_eq(detail, "oauth state mismatch")
    Err(error) =>
      fail("expected state mismatch, got: " + Show::to_string(error))
    Ok(_) => fail("a forged pasted state must not mint a credential")
  }
  assert_eq(transport_impl.requests.length(), 0)
}

///|
async test "unparseable paste is ignored and the callback still wins" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "late_code",
    block_until_stopped: false,
    raise_immediately: false,
    wait_delay_ms: 30,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let prompt_impl : ScriptedPromptInteraction = {
    inputs: ["this is not a url or code pair"],
    echo_url_code: "",
    delay_ms: 0,
    index: 0,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let prompt : &AuthPromptInteraction = prompt_impl
  let result = Ok(
    run_pkce_browser_flow(
      flow_config([], None),
      interaction,
      server,
      transport,
      prompt~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => assert_eq(credential.access_token, "access")
    Err(error) => fail("callback path failed: " + Show::to_string(error))
  }
  assert_true(
    transport_impl.requests[0].body.contains("&code=late_code&code_verifier="),
  )
}

///|
async test "failing server does not kill the paste path" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "",
    block_until_stopped: false,
    raise_immediately: true,
    wait_delay_ms: 0,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let prompt_impl : ScriptedPromptInteraction = {
    inputs: [],
    echo_url_code: "pasted_code",
    delay_ms: 0,
    index: 0,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let prompt : &AuthPromptInteraction = prompt_impl
  let result = Ok(
    run_pkce_browser_flow(
      flow_config([], None),
      interaction,
      server,
      transport,
      prompt~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => assert_eq(credential.access_token, "access")
    Err(error) => fail("paste path failed: " + Show::to_string(error))
  }
}

///|
async test "callback wins the race when it arrives first" {
  let interaction = RecordingAuthInteraction::new()
  let server_impl : FakeCallbackServer = {
    fail_ports: [],
    started_ports: [],
    interaction,
    delivered: None,
    delivered_code: "fast_code",
    block_until_stopped: false,
    raise_immediately: false,
    wait_delay_ms: 10,
    stop_count: 0,
  }
  let transport_impl : BrowserFlowTransport = {
    requests: [],
    response: OAuthHttpResponse::{ status: 200, body: TOKEN_BODY, },
    fail: false,
  }
  let prompt_impl : ScriptedPromptInteraction = {
    inputs: [],
    echo_url_code: "slow_pasted_code",
    delay_ms: 5000,
    index: 0,
  }
  let server : &CallbackServer = server_impl
  let transport : &OAuthHttpTransport = transport_impl
  let prompt : &AuthPromptInteraction = prompt_impl
  let result = Ok(
    run_pkce_browser_flow(
      flow_config([], None),
      interaction,
      server,
      transport,
      prompt~,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(credential) => assert_eq(credential.access_token, "access")
    Err(error) => fail("callback path failed: " + Show::to_string(error))
  }
  assert_true(
    transport_impl.requests[0].body.contains("&code=fast_code&code_verifier="),
  )
  assert_eq(server_impl.stop_count, 1)
}
