///|
async test "MoonBack HTTP gates headers and metadata retain the localhost contract" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let backend = @backend.BoardBackend()
      let server = NativeBoardWebServer(backend=Some(backend))
      let endpoint = server.bind().unwrap()
      defer server.close()
      group.spawn_bg(no_wait=true, () => {
        let _ = server.run()
      })
      let token = board_query_param(server.browser_url().unwrap(), "token").unwrap()
      for
        path in [
          "/health",
          "/api/bootstrap?token=" + token,
          "/?token=" + token,
          "/unknown?token=" + token,
        ] {
        let (response, body) = @http.get(endpoint.base_url() + path)
        assert_eq(response.headers.get("Cache-Control"), Some("no-store"))
        assert_eq(
          response.headers.get("X-Content-Type-Options"),
          Some("nosniff"),
        )
        assert_false(body.text().contains(token))
      }
      // http.get rewrites Host from its URL; raw requests exercise the gate.
      for
        host in [
          Some("evil.invalid"),
          Some("localhost:" + endpoint.port.to_string()),
          Some(""),
          None,
        ] {
        let tcp = @socket.Tcp::connect(
          @socket.Addr::parse(board_expected_host(endpoint)),
        )
        defer tcp.close()
        let host_header = match host {
          Some(value) => "Host: " + value + "\r\n"
          None => ""
        }
        tcp.write(
          "GET /health HTTP/1.1\r\n" + host_header + "Connection: close\r\n\r\n",
        )
        let raw = tcp.read_until("\r\n\r\n").unwrap()
        assert_true(raw.has_prefix("HTTP/1.1 403"))
        assert_true(raw.contains("no-store"))
        assert_true(raw.contains("nosniff"))
        assert_false(raw.contains(token))
      }
      for path in ["/", "/api/bootstrap", "/ws?token=wrong"] {
        let (response, body) = @http.get(endpoint.base_url() + path)
        assert_eq(response.code, 401)
        assert_eq(response.headers.get("Cache-Control"), Some("no-store"))
        assert_eq(
          response.headers.get("X-Content-Type-Options"),
          Some("nosniff"),
        )
        assert_false(body.text().contains(token))
      }
      let (forbidden, body) = @http.get(
        endpoint.base_url() + "/ws?token=" + token,
        headers={ "Origin": endpoint.base_url() + ".evil" },
      )
      assert_eq(forbidden.code, 403)
      assert_false(body.text().contains(token))
      let (health, health_body) = @http.get(endpoint.base_url() + "/health")
      assert_eq(health.code, 200)
      assert_eq(@json.parse(health_body.text()), {
        "ok": true,
        "service": "posoco-ext-board",
      })
      let (bootstrap, bootstrap_body) = @http.get(
        endpoint.base_url() + "/api/bootstrap?token=" + token,
      )
      assert_eq(bootstrap.code, 200)
      assert_eq(@json.parse(bootstrap_body.text()), {
        "protocol_version": 1,
        "host": "127.0.0.1",
        "port": endpoint.port.to_json(),
        "ws_path": "/ws",
      })
    })
  })
}

///|
async test "backend binding is idempotent before bind and cannot hot swap bound or running streams" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let first = @backend.BoardBackend(now_ms=() => 1234L)
      let second = @backend.BoardBackend()
      first.attach(group)
      second.attach(group)
      let server = NativeBoardWebServer()
      server.set_backend(first)
      server.set_backend(first)
      let endpoint = server.bind().unwrap()
      server.set_backend(second)
      assert_true(physical_equal(server.backend.unwrap(), first))
      assert_eq(server.app.unwrap().config().stop_timeout, 1.0)
      let serving = group.spawn(() => {
        let _ = server.run()
      })
      let ws = @websocket.connect(
        endpoint.ws_url() +
        "?token=" +
        board_query_param(server.browser_url().unwrap(), "token").unwrap(),
      )
      defer ws.close()
      board_test_hello(ws, 0L)
      guard board_test_frame(ws) is Snapshot(_) else {
        fail("expected bootstrap")
      }
      board_wait_clients(first, 1)
      server.set_backend(second)
      board_native_command(
        ws,
        "fixed-stream",
        "board.task.create",
        0L,
        board_native_create_args("fixed"),
      )
      guard board_test_frame(ws) is Event(created) else {
        fail("event before result")
      }
      assert_eq(created.board_revision, 1L)
      assert_true(board_native_result(ws, "fixed-stream").accepted)
      assert_eq(first.current_seq(), 1L)
      assert_eq(second.current_seq(), 0L)
      assert_eq(second.subscriber_count(), 0)
      server.close()
      serving.wait()
      board_wait_clients(first, 0)
      server.set_backend(second)
      assert_true(physical_equal(server.backend.unwrap(), second))
      first.shutdown()
      second.shutdown()
    })
  })
}

///|
async test "runtime closes active MoonBack websocket and headless backend remains usable" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let runtime = board_native_runtime(group, now_ms=() => 1234L)
      let backend = runtime.backend()
      let ws = @websocket.connect(board_native_url(runtime))
      defer ws.close()
      board_test_hello(ws, 0L)
      guard board_test_frame(ws) is Snapshot(_) else {
        fail("expected bootstrap")
      }
      board_wait_clients(backend, 1)
      @async.with_timeout(4000, () => runtime.close_server())
      assert_eq(runtime.status(), @runtime.Stopped)
      assert_eq(backend.subscriber_count(), 0)
      let closed = Some(ws.recv()) catch { _ => None }
      assert_true(closed is None)
      let result = backend.handle_command({
        command_id: "after-close",
        name: "board.task.create",
        expected_revision: 0L,
        args: board_native_create_args("headless"),
      })
      assert_true(result.accepted)
      assert_eq(result.current_revision, Some(1L))
      assert_true(backend.bootstrap_snapshot() is Ok(_))
      runtime.shutdown()
    })
  })
}
