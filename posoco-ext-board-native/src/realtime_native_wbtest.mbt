///|
async fn board_test_frame(ws : @websocket.Conn) -> @protocol.BoardServerFrame {
  let message = ws.recv()
  guard message.kind is Text else { fail("expected text") }
  let raw = message.read_all().text()
  match @protocol.decode_server_frame(raw) {
    Ok(frame) => frame
    Err(_) => fail("invalid server frame")
  }
}

///|
async fn board_test_hello(
  ws : @websocket.Conn,
  cursor : Int64,
  has_board_snapshot? : Bool = false,
) -> Unit {
  ws.send_text(
    @protocol.encode_client_frame(
      @protocol.Hello({
        last_seq: cursor,
        protocol_version: @protocol.protocol_version(),
        has_board_snapshot,
      }),
    ),
  )
}

///|
async fn board_wait_clients(
  backend : @backend.BoardBackend,
  count : Int,
) -> Unit {
  @async.with_timeout(1000, () => {
    while backend.subscriber_count() != count {
      @async.sleep(1)
    }
  })
}

///|
/// Telemetry fixture: the only way tests mint stream events without a
/// commit.
fn board_backend_tick(
  backend : @backend.BoardBackend,
) -> @protocol.BoardWireEvent {
  backend.publish_telemetry(board_revision=0L, kind="assistant.delta", payload={
    "text": "[redacted]",
  })
}

///|
async test "native shared runtime hello live reconnect two three and command rejection" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let runtime = default_board_runtime(8, client_queue_depth=2)
      runtime.attach(group)
      let endpoint = match runtime.ensure_server() {
        Ok(value) => value
        Err(_) => fail("bind failed")
      }
      let token = board_query_param(
        runtime.server.browser_url().unwrap(),
        "token",
      ).unwrap()
      let url = endpoint.ws_url() + "?token=" + token
      let first = runtime.publish_telemetry(
        board_revision=0L,
        kind="assistant.delta",
        scope=Some({
          session_id: Some("s"),
          run_id: Some("r"),
          turn_id: Some("t"),
        }),
        payload={ "text": "[redacted]" },
      )
      let ws = @websocket.connect(url, headers={ "Origin": endpoint.base_url() })
      defer ws.close()
      board_test_hello(ws, 0L)
      guard board_test_frame(ws) is Snapshot(snapshot) else {
        fail("snapshot required")
      }
      assert_eq(snapshot.last_seq, 1L)
      assert_eq(snapshot.board_revision, 0L)
      assert_eq(snapshot.payload, {
        "board": { "revision": Json::number(0), "tasks": [], "attempts": [] },
        "events": [first.to_json()],
      })
      let second = runtime.publish_telemetry(
        board_revision=0L,
        kind="run.completed",
        payload={},
      )
      assert_eq(board_test_frame(ws), @protocol.Event(second))
      ws.close()
      board_wait_clients(runtime.backend(), 0)
      let third = runtime.publish_telemetry(
        board_revision=0L,
        kind="run.started",
        payload={},
      )
      let reconnect = @websocket.connect(url)
      defer reconnect.close()
      board_test_hello(reconnect, 1L, has_board_snapshot=true)
      assert_eq(board_test_frame(reconnect), @protocol.Event(second))
      assert_eq(board_test_frame(reconnect), @protocol.Event(third))
      reconnect.send_text(
        @protocol.encode_client_frame(
          @protocol.Command({
            command_id: "c-1",
            name: "board.mutate",
            expected_revision: 0L,
            args: { "opaque": "never reflected" },
          }),
        ),
      )
      assert_eq(
        board_test_frame(reconnect),
        @protocol.CommandResult({
          command_id: "c-1",
          accepted: false,
          error: Some("invalid_command"),
          current_revision: Some(0L),
        }),
      )
      assert_eq(runtime.current_seq(), 3L)
      assert_eq(runtime.event_history(), [first, second, third])
      runtime.shutdown()
      assert_eq(runtime.backend().subscriber_count(), 0)
    })
  })
}

///|
async test "native first command version cursor binary and oversized frames are rejected" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let backend = @backend.BoardBackend::BoardBackend()
      let server = NativeBoardWebServer::NativeBoardWebServer(
        backend=Some(backend),
      )
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
      let cases = [
        (
          @protocol.encode_client_frame(
            @protocol.Command({
              command_id: "first",
              name: "x",
              expected_revision: 0L,
              args: {},
            }),
          ),
          "hello_required",
        ),
        (
          "{\"type\":\"hello\",\"last_seq\":0,\"protocol_version\":2}", "unsupported_version",
        ),
        (
          "{\"type\":\"hello\",\"last_seq\":-1,\"protocol_version\":1}", "invalid_hello",
        ),
        (String::from_array(Array::make(8193, 'x')), "frame_too_large"),
      ]
      for (raw, code) in cases {
        let ws = @websocket.connect(url)
        defer ws.close()
        ws.send_text(raw)
        guard board_test_frame(ws) is Error(code=actual, ..) else {
          fail("expected clear rejection")
        }
        assert_eq(actual, code)
        assert_eq(backend.subscriber_count(), 0)
        assert_eq(backend.current_seq(), 0L)
        let closed = Some(ws.recv()) catch { _ => None }
        assert_true(closed is None)
      }
      let binary = @websocket.connect(url)
      defer binary.close()
      binary.send_binary(b"{}")
      guard board_test_frame(binary) is Error(code="expected_text", ..) else {
        fail("binary Hello must be rejected")
      }
      assert_eq(backend.subscriber_count(), 0)
    })
  })
}

///|
async test "native retained snapshot security gates and connection cleanup" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let backend = @backend.BoardBackend::BoardBackend(event_buffer=2)
      let server = NativeBoardWebServer::NativeBoardWebServer(
        backend=Some(backend),
      )
      let opener : FakeBrowserOpener = { opened: [], }
      let runtime = BoardRuntime::with_adapters(backend~, server~, opener~)
      runtime.attach(group)
      assert_true(runtime.backend().bootstrap_snapshot() is Ok(_))
      let endpoint = match runtime.ensure_server() {
        Ok(value) => value
        Err(_) => fail("bind failed")
      }
      let token = board_query_param(
        runtime.server.browser_url().unwrap(),
        "token",
      ).unwrap()
      let url = endpoint.ws_url() + "?token=" + token
      let bad_headers : Array[Map[@http.CaseInsensitiveString, String]] = [
        { "Host": "evil.invalid" },
        { "Origin": "http://evil.invalid" },
      ]
      for headers in bad_headers {
        let denied = Some(@websocket.connect(url, headers~)) catch { _ => None }
        assert_true(denied is None)
      }
      let missing = Some(@websocket.connect(endpoint.ws_url())) catch {
        _ => None
      }
      assert_true(missing is None)
      assert_eq(backend.subscriber_count(), 0)
      for _ in 0..<4 {
        let _ = board_backend_tick(backend)
      }
      for cursor in [0L, 1L, 4L, 99L] {
        let ws = @websocket.connect(url)
        defer ws.close()
        board_test_hello(ws, cursor)
        guard board_test_frame(ws) is Snapshot(snapshot) else {
          fail("retained snapshot required")
        }
        assert_eq(snapshot.last_seq, 4L)
        assert_eq(snapshot.board_revision, 0L)
        // Every unserveable cursor receives the same authoritative
        // composite: the committed board plus the retained event suffix.
        assert_eq(snapshot.payload, {
          "board": { "revision": Json::number(0), "tasks": [], "attempts": [] },
          "events": backend.event_history().map(event => event.to_json()),
        })
        assert_false(snapshot.payload.stringify().contains(token))
        ws.close()
        board_wait_clients(backend, 0)
      }
      let current = @websocket.connect(url)
      defer current.close()
      board_test_hello(current, 4L, has_board_snapshot=true)
      board_wait_clients(backend, 1)
      let live = board_backend_tick(backend)
      assert_eq(board_test_frame(current), @protocol.Event(live))
      runtime.close_server()
      board_wait_clients(backend, 0)
      assert_eq(runtime.status(), Stopped)
      let closed = Some(current.recv()) catch { _ => None }
      assert_true(closed is None)
      runtime.shutdown()
    })
  })
}

///|
async test "native overflow sends resync closes and reset zero snapshots" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let backend = @backend.BoardBackend::BoardBackend(client_queue_depth=2)
      let server = NativeBoardWebServer::NativeBoardWebServer(
        backend=Some(backend),
      )
      let opener : FakeBrowserOpener = { opened: [], }
      let runtime = BoardRuntime::with_adapters(backend~, server~, opener~)
      runtime.attach(group)
      assert_true(runtime.backend().bootstrap_snapshot() is Ok(_))
      let endpoint = match runtime.ensure_server() {
        Ok(value) => value
        Err(_) => fail("bind failed")
      }
      let token = board_query_param(
        runtime.server.browser_url().unwrap(),
        "token",
      ).unwrap()
      let url = endpoint.ws_url() + "?token=" + token
      let ws = @websocket.connect(url)
      defer ws.close()
      board_test_hello(ws, 0L)
      guard board_test_frame(ws) is Snapshot(initial_snapshot) else {
        fail("initial snapshot required before the live overflow burst")
      }
      assert_eq(initial_snapshot.last_seq, 0L)
      board_wait_clients(backend, 1)
      for _ in 0..<4 {
        let _ = board_backend_tick(backend)
      }
      assert_eq(
        board_test_frame(ws),
        @protocol.ResyncRequired(reason="client_queue_overflow", current_seq=4L),
      )
      let closed = Some(ws.recv()) catch { _ => None }
      assert_true(closed is None)
      board_wait_clients(backend, 0)
      let reconnect = @websocket.connect(url)
      defer reconnect.close()
      board_test_hello(reconnect, 0L)
      guard board_test_frame(reconnect) is Snapshot(snapshot) else {
        fail("reset requires snapshot")
      }
      // The reset snapshot is authoritative: committed board plus the full
      // retained telemetry suffix.
      assert_eq(snapshot.last_seq, 4L)
      assert_eq(snapshot.board_revision, 0L)
      assert_eq(snapshot.payload, {
        "board": { "revision": Json::number(0), "tasks": [], "attempts": [] },
        "events": backend.event_history().map(event => event.to_json()),
      })
      runtime.close_server()
      board_wait_clients(backend, 0)
      runtime.shutdown()
    })
  })
}

///|
/// Startup store whose load parks until released, so a test parks the
/// backend's bootstrap at the durability boundary.
priv struct GatedLoadStore {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
impl @store.BoardStore for GatedLoadStore with fn load(self) {
  self.entered.put(())
  self.release.get()
  Ok({ snapshot: @store.empty_snapshot(), journal: [], })
}

///|
impl @store.BoardStore for GatedLoadStore with fn persist(
  _self,
  _snapshot,
  _events,
) {
  fail("empty startup must not persist")
}

///|
async test "native overflow during bootstrap await resyncs and never installs the snapshot" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let store : GatedLoadStore = {
        entered: @aqueue.Queue(kind=@aqueue.Blocking(1)),
        release: @aqueue.Queue(kind=@aqueue.Blocking(1)),
      }
      let backend = @backend.BoardBackend::BoardBackend(
        store~,
        client_queue_depth=1,
      )
      let server = NativeBoardWebServer::NativeBoardWebServer(
        backend=Some(backend),
      )
      backend.attach(group)
      @async.with_timeout(1000, () => store.entered.get())
      let endpoint = match server.bind() {
        Ok(value) => value
        Err(_) => fail("bind failed")
      }
      defer server.close()
      group.spawn_bg(no_wait=true, () => {
        let _ = server.run()
      })
      // One tick before connecting: Hello 0 plans SnapshotRequired.
      let _ = board_backend_tick(backend)
      let token = board_query_param(server.browser_url().unwrap(), "token").unwrap()
      let ws = @websocket.connect(endpoint.ws_url() + "?token=" + token)
      defer ws.close()
      board_test_hello(ws, 0L)
      // Wait for registration, not just startup load: the snapshot await
      // must be in flight before overflowing this connection's mailbox.
      board_wait_clients(backend, 1)
      // The depth-one mailbox overflows while the bootstrap is still awaited.
      let _ = board_backend_tick(backend)
      let _ = board_backend_tick(backend)
      store.release.put(())
      assert_eq(
        board_test_frame(ws),
        @protocol.ResyncRequired(reason="client_queue_overflow", current_seq=3L),
      )
      // The connection closes and no snapshot frame is ever delivered.
      let closed = Some(ws.recv()) catch { _ => None }
      assert_true(closed is None)
      board_wait_clients(backend, 0)
    })
  })
}

///|
async test "native shutdown cancels a reader still waiting for Hello" {
  @async.with_timeout(2000, () => {
    @async.with_task_group(group => {
      let backend = @backend.BoardBackend::BoardBackend()
      let server = NativeBoardWebServer::NativeBoardWebServer(
        backend=Some(backend),
      )
      let endpoint = match server.bind() {
        Ok(value) => value
        Err(_) => fail("bind failed")
      }
      defer server.close()
      let serving = group.spawn(() => {
        let _ = server.run()
      })
      let token = board_query_param(server.browser_url().unwrap(), "token").unwrap()
      let ws = @websocket.connect(endpoint.ws_url() + "?token=" + token)
      defer ws.close()
      // The completed upgrade proves MoonBack owns the pending Hello reader.
      server.close()
      serving.wait()
      assert_eq(backend.subscriber_count(), 0)
      let closed = Some(ws.recv()) catch { _ => None }
      assert_true(closed is None)
    })
  })
}

///|
async test "native Hello deadline closes without subscription" {
  @async.with_timeout(7000, () => {
    @async.with_task_group(group => {
      let backend = @backend.BoardBackend::BoardBackend()
      let server = NativeBoardWebServer::NativeBoardWebServer(
        backend=Some(backend),
      )
      let endpoint = match server.bind() {
        Ok(value) => value
        Err(_) => fail("bind failed")
      }
      defer server.close()
      group.spawn_bg(no_wait=true, () => {
        let _ = server.run()
      })
      let token = board_query_param(server.browser_url().unwrap(), "token").unwrap()
      let ws = @websocket.connect(endpoint.ws_url() + "?token=" + token)
      defer ws.close()
      guard board_test_frame(ws) is Error(code="hello_timeout", ..) else {
        fail("Hello must have a deadline")
      }
      assert_eq(backend.subscriber_count(), 0)
    })
  })
}
