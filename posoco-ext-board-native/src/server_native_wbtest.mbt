///|
async fn board_http_get(url : String) -> (Int, String) {
  let (response, body) = @http.get(url)
  (response.code, body.text())
}

///|
async test "native server binds loopback random port and guards bootstrap" {
  let server = NativeBoardWebServer::NativeBoardWebServer(
    backend=Some(@backend.BoardBackend::BoardBackend()),
  )
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
  let server = NativeBoardWebServer::NativeBoardWebServer(
    backend=Some(@backend.BoardBackend::BoardBackend()),
  )
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
async test "native server refuses to bind until a backend is installed and then serves it" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let server = NativeBoardWebServer::NativeBoardWebServer()
      let web : &BoardWebServer = server
      // Presentation plumbing without a backend must not serve anything.
      assert_eq(web.bind(), Err("board backend not installed"))
      let backend = @backend.BoardBackend::BoardBackend()
      web.set_backend(backend)
      let endpoint = match web.bind() {
        Ok(value) => value
        Err(_) => fail("bind failed with an installed backend")
      }
      defer server.close()
      group.spawn_bg(no_wait=true, () => {
        let _ = server.run()
      })
      let token = board_query_param(server.browser_url().unwrap(), "token").unwrap()
      let ws = @websocket.connect(endpoint.ws_url() + "?token=" + token)
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(backend, 1)
      // The installed backend owns the authoritative answer; the rejection
      // is a decoded-command verdict, not a stage-neutral stub.
      ws.send_text(
        @protocol.encode_client_frame(
          @protocol.Command({
            command_id: "served-1",
            name: "board.task.destroy",
            expected_revision: 7L,
            args: {},
          }),
        ),
      )
      assert_eq(
        board_test_frame(ws),
        @protocol.CommandResult({
          command_id: "served-1",
          accepted: false,
          error: Some("invalid_command"),
          current_revision: None,
        }),
      )
      assert_eq(backend.current_seq(), 0L)
      ws.close()
      board_wait_clients(backend, 0)
    })
  })
}

///|
async test "native close_server keeps the backend and reopens with fresh ws state" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let backend = @backend.BoardBackend::BoardBackend(now_ms=() => 1234L)
      let server = NativeBoardWebServer::NativeBoardWebServer()
      let opener : FakeBrowserOpener = { opened: [], }
      let runtime = BoardRuntime::with_adapters(backend~, server~, opener~)
      runtime.attach(group)
      assert_true(runtime.backend().bootstrap_snapshot() is Ok(_))
      let first = runtime.ensure_server().unwrap()
      let first_url = board_native_url(runtime)
      let ws = @websocket.connect(first_url)
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(backend, 1)
      board_native_command(ws, "open-1", "board.task.create", 0L, {
        "id": "t1",
        "title": "task t1",
        "description": "",
        "priority": "normal",
        "definition_of_done": [],
        "dependencies": [],
      })
      guard board_test_frame(ws) is Event(created) else {
        fail("expected the created event before the result")
      }
      assert_eq(created.seq, 1L)
      assert_true(board_native_result(ws, "open-1").accepted)
      ws.close()
      board_wait_clients(backend, 0)
      // close_server only tears the presentation down; the backend keeps
      // serving headless commands and never loses its stream.
      runtime.close_server()
      assert_eq(runtime.status(), Stopped)
      assert_false(server.is_alive())
      let headless = backend.handle_command({
        command_id: "headless-2",
        name: "board.task.create",
        expected_revision: 1L,
        args: {
          "id": "t2",
          "title": "task t2",
          "description": "",
          "priority": "normal",
          "definition_of_done": [],
          "dependencies": [],
        },
      })
      assert_eq(headless.accepted, true)
      assert_eq(headless.current_revision, Some(2L))
      assert_eq(backend.current_seq(), 2L)
      // Reopening binds a fresh listener whose state is the committed one.
      let second = runtime.ensure_server().unwrap()
      assert_true(second.port != first.port)
      let fresh = @websocket.connect(board_native_url(runtime))
      defer fresh.close()
      board_test_hello(fresh, 0L)
      guard board_test_frame(fresh) is Snapshot(snapshot) else {
        fail("the reopened listener must serve the committed state")
      }
      assert_eq(snapshot.last_seq, 2L)
      assert_eq(snapshot.board_revision, 2L)
      let board = board_native_section(snapshot.payload, "board")
      assert_eq(
        board_native_items(board_native_section(board, "tasks")).length(),
        2,
      )
      runtime.close_server()
      runtime.shutdown()
    })
  })
}
