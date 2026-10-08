///|
async test "native observer projection stays sanitized through live and retained reset" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let backend = @backend.BoardBackend::BoardBackend(event_buffer=2)
      let server = NativeBoardWebServer(backend=Some(backend))
      let runtime = @runtime.BoardRuntime::with_adapters(
        backend~,
        server~,
        opener=NativeBrowserOpener(),
      )
      let board = @board.BoardExtension::with_runtime(runtime~)
      board.attach(group)
      let endpoint = match runtime.ensure_server() {
        Ok(value) => value
        Err(_) => fail("bind failed")
      }
      let browser = server.browser_url().unwrap()
      let query = browser.split("?").to_array()[1].to_owned()
      let url = endpoint.ws_url() + "?" + query
      let ws = @websocket.connect(url)
      defer ws.close()
      board.on_event(
        StreamChunkReceived(chunk=TextDelta(token="API_KEY=PRIVATE_SENTINEL")),
      )
      ws.send_text(
        @protocol.encode_client_frame(
          @protocol.Hello({
            last_seq: 0L,
            protocol_version: 1,
            has_board_snapshot: false,
          }),
        ),
      )
      let bootstrap = ws.recv().read_all().text()
      assert_false(bootstrap.contains("PRIVATE_SENTINEL"))
      assert_true(bootstrap.contains("[redacted]"))
      board.on_event(TurnFailed("PROVIDER_SENTINEL"))
      let live = ws.recv().read_all().text()
      assert_false(live.contains("PROVIDER_SENTINEL"))
      guard @protocol.decode_server_frame(live) is Ok(Event(event)) else {
        fail("expected live event")
      }
      assert_eq(event.seq, 2L)
      assert_eq(event.board_revision, 0L)
      assert_eq(event.payload, { "preview": "Run failed" })
      ws.close()
      board.on_event(
        StreamChunkReceived(chunk=TextDelta(token="secret=SECOND_SENTINEL")),
      )
      board.on_event(
        StreamChunkReceived(
          chunk=ReasoningDelta(token="password=THIRD_SENTINEL"),
        ),
      )
      let reconnect = @websocket.connect(url)
      defer reconnect.close()
      reconnect.send_text(
        @protocol.encode_client_frame(
          @protocol.Hello({
            last_seq: 1L,
            protocol_version: 1,
            has_board_snapshot: true,
          }),
        ),
      )
      let raw = reconnect.recv().read_all().text()
      assert_false(raw.contains("SENTINEL"))
      guard @protocol.decode_server_frame(raw) is Ok(Snapshot(snapshot)) else {
        fail("gap requires authoritative snapshot")
      }
      assert_eq(snapshot.last_seq, 4L)
      assert_eq(snapshot.board_revision, 0L)
      // The retained reset is the authoritative composite: sanitized board
      // projection plus the retained sanitized telemetry suffix.
      assert_eq(snapshot.payload, {
        "board": { "revision": Json::number(0), "tasks": [], "attempts": [] },
        "events": runtime.event_history().map(event => event.to_json()),
      })
      assert_false(raw.contains("PRIVATE_SENTINEL"))
      assert_eq(runtime.event_history().length(), 2)
      runtime.shutdown()
      assert_eq(backend.subscriber_count(), 0)
    })
  })
}
