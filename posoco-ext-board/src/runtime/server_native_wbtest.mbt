///|
async fn board_http_get(url : String) -> (Int, String) {
  let (response, body) = @http.get(url)
  (response.code, body.text())
}

///|
async test "native server binds loopback random port and guards bootstrap" {
  let server = NativeBoardWebServer::NativeBoardWebServer()
  let web : &BoardWebServer = server
  @async.with_task_group(group => {
    let endpoint = match web.bind() {
      Ok(value) => value
      Err(error) => fail("unexpected bind error: \{error}")
    }
    assert_eq(endpoint.host, "127.0.0.1")
    assert_true(endpoint.port > 0)
    group.spawn_bg(no_wait=true, allow_failure=true, () => {
      let _ = web.run()
    })
    @async.sleep(10)

    let (health_code, health_body) = board_http_get(endpoint.base_url() + "/health")
    assert_eq(health_code, 200)
    assert_true(health_body.contains("\"ok\":true"))
    assert_false(health_body.contains("token"))

    let (denied_code, _denied_body) = board_http_get(
      endpoint.base_url() + "/api/bootstrap",
    )
    assert_eq(denied_code, 401)

    let browser_url = match web.browser_url() {
      Some(value) => value
      None => fail("running server must expose browser bootstrap URL")
    }
    let token = match board_query_param(browser_url, "token") {
      Some(value) => value
      None => fail("bootstrap URL must carry an instance token")
    }
    assert_eq(token.length(), 64)

    let (bootstrap_code, bootstrap_body) = board_http_get(
      endpoint.base_url() + "/api/bootstrap?token=" + token,
    )
    assert_eq(bootstrap_code, 200)
    assert_true(bootstrap_body.contains("\"protocol_version\":1"))
    assert_false(bootstrap_body.contains(token))

    let bad : Result[@websocket.Conn, Error] = Ok(
      @websocket.connect(endpoint.ws_url() + "?token=wrong"),
    ) catch {
      error => Err(error)
    }
    assert_true(bad is Err(_))

    let bad_origin : Result[@websocket.Conn, Error] = Ok(
      @websocket.connect(
        endpoint.ws_url() + "?token=" + token,
        headers={ "Origin": "http://example.invalid" },
      ),
    ) catch {
      error => Err(error)
    }
    assert_true(bad_origin is Err(_))

    let ws = @websocket.connect(
      endpoint.ws_url() + "?token=" + token,
      headers={ "Origin": endpoint.base_url() },
    )
    ws.send_close()
    ws.close()
    web.close()
  })
}

///|
async test "native close is idempotent and rebind mints fresh secret" {
  let server = NativeBoardWebServer::NativeBoardWebServer()
  let web : &BoardWebServer = server
  @async.with_task_group(group => {
    let first = match web.bind() {
      Ok(value) => value
      Err(error) => fail("unexpected bind error: \{error}")
    }
    let first_url = web.browser_url().unwrap()
    group.spawn_bg(no_wait=true, allow_failure=true, () => {
      let _ = web.run()
    })
    web.close()
    web.close()
    assert_false(web.is_alive())

    let second = match web.bind() {
      Ok(value) => value
      Err(error) => fail("unexpected rebind error: \{error}")
    }
    let second_url = web.browser_url().unwrap()
    assert_eq(first.host, second.host)
    assert_true(second.port > 0)
    assert_true(first_url != second_url)
    web.close()
  })
}
