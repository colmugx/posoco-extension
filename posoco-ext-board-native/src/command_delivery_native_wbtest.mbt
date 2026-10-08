///|
/// Gated store for delivery-order tests: a persist parks until released, so
/// the test controls exactly when a command's commit event is enqueued.
priv struct DeliveryGateStore {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  mut durable : @domain.BoardStateSnapshot
}

///|
fn DeliveryGateStore::DeliveryGateStore() -> DeliveryGateStore {
  {
    entered: @aqueue.Queue(kind=@aqueue.Blocking(1)),
    release: @aqueue.Queue(kind=@aqueue.Blocking(1)),
    durable: @store.empty_snapshot(),
  }
}

///|
impl @store.BoardStore for DeliveryGateStore with fn load(self) {
  Ok({ snapshot: self.durable.copy_detached(), journal: [], })
}

///|
impl @store.BoardStore for DeliveryGateStore with fn persist(
  self,
  snapshot,
  _events,
) {
  self.entered.put(())
  self.release.get()
  self.durable = snapshot.copy_detached()
  Ok(())
}

///|
async test "native command result follows every event published before it" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let store = DeliveryGateStore::DeliveryGateStore()
      let backend = @backend.BoardBackend::BoardBackend(store~, now_ms=() => {
        1234L
      })
      let server = NativeBoardWebServer::NativeBoardWebServer()
      let opener : FakeBrowserOpener = { opened: [], }
      let runtime = BoardRuntime::with_adapters(backend~, server~, opener~)
      runtime.attach(group)
      assert_true(runtime.backend().bootstrap_snapshot() is Ok(_))
      assert_true(runtime.ensure_server() is Ok(_))
      let ws = @websocket.connect(board_native_url(runtime))
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(runtime.backend(), 1)
      board_native_command(
        ws,
        "batch",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      // The mutation is parked at the store. Telemetry published in the
      // meantime streams to the live client before the commit settles.
      store.entered.get()
      let first = backend.publish_telemetry(
        board_revision=1L,
        kind="board.test.first",
        payload={},
      )
      let second = backend.publish_telemetry(
        board_revision=1L,
        kind="board.test.second",
        payload={},
      )
      store.release.put(())
      guard board_test_frame(ws) is Event(delivered_first) else {
        fail("expected first event")
      }
      guard board_test_frame(ws) is Event(delivered_second) else {
        fail("expected second event")
      }
      assert_eq([delivered_first, delivered_second], [first, second])
      assert_eq(first.seq, 1L)
      assert_eq(second.seq, 2L)
      // The commit event and only then the local correlated result.
      guard board_test_frame(ws) is Event(created) else {
        fail("expected the created event before the result")
      }
      assert_eq(created.seq, 3L)
      assert_eq(created.kind, "board.task.created")
      assert_eq(board_native_result(ws, "batch"), {
        command_id: "batch",
        accepted: true,
        error: None,
        current_revision: Some(1L),
      })
      assert_eq(runtime.event_history(), [first, second, created])
      assert_eq(runtime.current_seq(), 3L)
      runtime.shutdown()
    })
  })
}

///|
async test "native command result overflow resyncs without rolling back the durable mutation" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let store = DeliveryGateStore::DeliveryGateStore()
      let backend = @backend.BoardBackend::BoardBackend(
        store~,
        client_queue_depth=1,
        now_ms=() => 1234L,
      )
      let server = NativeBoardWebServer::NativeBoardWebServer()
      let opener : FakeBrowserOpener = { opened: [], }
      let runtime = BoardRuntime::with_adapters(backend~, server~, opener~)
      runtime.attach(group)
      assert_true(runtime.backend().bootstrap_snapshot() is Ok(_))
      assert_true(runtime.ensure_server() is Ok(_))
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
      // The mutation parks at the store. While it is parked the depth-one
      // mailbox fills and overflows, so the answered snapshot would already
      // be stale by the time it arrives.
      store.entered.get()
      let _tick_one = backend.publish_telemetry(
        board_revision=1L,
        kind="board.test.tick",
        payload={},
      )
      let _tick_two = backend.publish_telemetry(
        board_revision=1L,
        kind="board.test.tick",
        payload={},
      )
      store.release.put(())
      // Depending on sender scheduling, the first tick may already have
      // been sent. A result must never be silently dropped or sent after resync.
      let terminal = match board_test_frame(ws) {
        Event(event) => {
          assert_eq(event.kind, "board.test.tick")
          board_test_frame(ws)
        }
        frame => frame
      }
      assert_eq(
        terminal,
        @protocol.ResyncRequired(reason="client_queue_overflow", current_seq=3L),
      )
      let closed = Some(ws.recv()) catch { _ => None }
      assert_true(closed is None)
      board_wait_clients(backend, 0)
      assert_eq(
        runtime.backend().bootstrap_snapshot().unwrap().board_revision,
        1L,
      )
      assert_eq(
        runtime
        .event_history()
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
      assert_eq(snapshot.last_seq, 3L)
      runtime.shutdown()
    })
  })
}
