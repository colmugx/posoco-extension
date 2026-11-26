///|
/// A port nothing listens on: bind on 0, read it back, close.
async fn free_loopback_port() -> UInt16 {
  let probe = @socket.TcpServer(@socket.Addr::resolve("127.0.0.1", port=0))
  let port = probe.local_addr().port
  probe.close()
  port
}

///|
async test "native callback wait times out as ExpiredToken when nobody calls back" {
  let port = free_loopback_port()
  let server = @ext-oauth.NativeCallbackServer::NativeCallbackServer(
    wait_timeout_ms=200,
  )
  server.start(port.to_int())
  defer server.stop()
  let started = @async.now()
  let outcome : Result[(String, String), @ext-oauth.OAuthError] = Ok(
    server.wait_callback(),
  ) catch {
    err => Err(err)
  }
  guard outcome is Err(@ext-oauth.OAuthError::ExpiredToken) else {
    fail("expected ExpiredToken for an abandoned login")
  }
  assert_true(@async.now() - started < 5_000L)
}

///|
async test "native callback returns the code and state of the redirect" {
  let port = free_loopback_port()
  let server = @ext-oauth.NativeCallbackServer::NativeCallbackServer()
  server.start(port.to_int())
  defer server.stop()
  @async.with_task_group() <| group => {
    group.spawn_bg(async fn() {
      let (response, _) = @http.get(
        "http://127.0.0.1:\{port}/auth/callback?code=abc&state=s1",
      )
      assert_eq(response.code, 200)
    })
    let (code, state) = server.wait_callback()
    assert_eq(code, "abc")
    assert_eq(state, "s1")
  }
}
