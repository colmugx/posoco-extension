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

    let (health_code, health_body) = board_http_get(
      endpoint.base_url() + "/health",
    )
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
      @websocket.connect(endpoint.ws_url() + "?token=" + token, headers={
        "Origin": "http://example.invalid",
      }),
    ) catch {
      error => Err(error)
    }
    assert_true(bad_origin is Err(_))

    let ws = @websocket.connect(endpoint.ws_url() + "?token=" + token, headers={
      "Origin": endpoint.base_url(),
    })
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

///|
async test "native command seam defaults to unsupported and serves installed handler" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let hub = BoardEventHub()
      let server = NativeBoardWebServer(hub~)
      let endpoint = match server.bind() {
        Ok(value) => value
        Err(_) => fail("bind failed")
      }
      defer server.close()
      group.spawn_bg(no_wait=true, () => {
        let _ = server.run()
      })
      let token = board_query_param(server.browser_url().unwrap(), "token").unwrap()
      let url = endpoint.ws_url() + "?token=" + token
      // An isolated server without an installed handler still answers the
      // stage-neutral rejection on the issuing connection; nothing is
      // mutated and nothing is published into the hub stream.
      let bare = @websocket.connect(url)
      board_test_hello(bare, 0L, has_board_snapshot=true)
      board_wait_clients(hub, 1)
      bare.send_text(
        @protocol.encode_client_frame(
          @protocol.Command({
            command_id: "bare-1",
            name: "board.task.create",
            expected_revision: 0L,
            args: { "id": "t1", "title": "task" },
          }),
        ),
      )
      assert_eq(
        board_test_frame(bare),
        @protocol.CommandResult({
          command_id: "bare-1",
          accepted: false,
          error: Some("unsupported_in_current_stage"),
          current_revision: None,
        }),
      )
      assert_eq(hub.current_seq(), 0L)
      bare.close()
      board_wait_clients(hub, 0)
      // Installing a handler through the symmetric seam redirects the same
      // path to the authoritative answer. The result stays scoped to this
      // connection and the hub history remains untouched.
      server.set_command_handler(fn(command) {
        {
          command_id: command.command_id,
          accepted: true,
          error: None,
          current_revision: Some(command.expected_revision + 1L),
        }
      })
      let served = @websocket.connect(url)
      board_test_hello(served, 0L, has_board_snapshot=true)
      board_wait_clients(hub, 1)
      served.send_text(
        @protocol.encode_client_frame(
          @protocol.Command({
            command_id: "served-1",
            name: "board.task.create",
            expected_revision: 7L,
            args: {},
          }),
        ),
      )
      assert_eq(
        board_test_frame(served),
        @protocol.CommandResult({
          command_id: "served-1",
          accepted: true,
          error: None,
          current_revision: Some(8L),
        }),
      )
      assert_eq(hub.current_seq(), 0L)
      served.close()
      board_wait_clients(hub, 0)
    })
  })
}
