///|
async test "native command seam preserves a multi-event batch before its local result" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let hub = BoardEventHub()
      let server = NativeBoardWebServer(hub~)
      let emitted : Array[@protocol.BoardWireEvent] = []
      server.set_command_handler(command => {
        for kind in ["board.test.first", "board.test.second"] {
          emitted.push(hub.publish(board_revision=1L, kind~, payload={}))
        }
        {
          command_id: command.command_id,
          accepted: true,
          error: None,
          current_revision: Some(1L),
        }
      })
      let endpoint = server.bind().unwrap()
      defer server.close()
      group.spawn_bg(no_wait=true, () => {
        let _ = server.run()
      })
      let token = board_query_param(server.browser_url().unwrap(), "token").unwrap()
      let ws = @websocket.connect(endpoint.ws_url() + "?token=" + token)
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(hub, 1)
      board_native_command(ws, "batch", "test.batch", 0L, {})
      guard board_test_frame(ws) is Event(first) else {
        fail("expected first event")
      }
      guard board_test_frame(ws) is Event(second) else {
        fail("expected second event")
      }
      assert_eq([first, second], emitted)
      assert_eq(first.seq, 1L)
      assert_eq(second.seq, 2L)
      assert_eq(board_native_result(ws, "batch"), {
        command_id: "batch",
        accepted: true,
        error: None,
        current_revision: Some(1L),
      })
      assert_eq(hub.history(), emitted)
      assert_eq(hub.current_seq(), 2L)
    })
  })
}

///|
async test "native command result overflow resyncs without rolling back the durable mutation" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let hub = BoardEventHub(client_queue_depth=1)
      let server = NativeBoardWebServer(hub~)
      let opener : FakeBrowserOpener = { opened: [], }
      let runtime = BoardRuntime::with_adapters(hub~, server~, opener~, now_ms=() => {
        1234L
      })
      runtime.attach(group)
      assert_true(runtime.coordinator.wait_ready() is Ok(_))
      assert_true(runtime.ensure_server() is Ok(_))
      // Occupy the last mailbox slot synchronously immediately before the
      // server enqueues the response. No sender can interleave this burst.
      server.set_command_handler(async fn(command) {
        let result = runtime.handle_command(command)
        let _ = hub.publish(board_revision=1L, kind="test.fill", payload={})
        result
      })
      let ws = @websocket.connect(board_native_url(runtime))
      defer ws.close()
      board_test_hello(ws, 0L)
      guard board_test_frame(ws) is Snapshot(_) else {
        fail("expected snapshot")
      }
      board_native_command(
        ws,
        "overflow",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      // Depending on sender scheduling, the commit event may already have
      // been sent. A result must never be silently dropped or sent after resync.
      let terminal = match board_test_frame(ws) {
        Event(event) => {
          assert_eq(event.kind, "board.task.created")
          board_test_frame(ws)
        }
        frame => frame
      }
      assert_eq(
        terminal,
        @protocol.ResyncRequired(reason="client_queue_overflow", current_seq=2L),
      )
      let closed = Some(ws.recv()) catch { _ => None }
      assert_true(closed is None)
      board_wait_clients(hub, 0)
      assert_eq(runtime.coordinator.revision(), Ok(1L))
      assert_eq(runtime.coordinator.snapshot().unwrap().tasks.length(), 1)
      assert_eq(
        hub
        .history()
        .filter(event => event.kind == "board.task.created")
        .length(),
        1,
      )
      // A fresh client learns the committed truth without resending the command.
      let fresh = @websocket.connect(board_native_url(runtime))
      defer fresh.close()
      board_test_hello(fresh, 0L)
      guard board_test_frame(fresh) is Snapshot(snapshot) else {
        fail("expected fresh snapshot")
      }
      assert_eq(snapshot.board_revision, 1L)
      assert_eq(snapshot.last_seq, 2L)
      runtime.shutdown()
    })
  })
}
