///|
/// Runtime lifecycle tests: presentation ownership only. The backend is
/// exercised headless in `src/backend`; here the fake adapters prove the
/// runtime binds, opens, closes and settles exactly once.
priv struct FakeBoardServer {
  mut backend_installed : Bool
  mut binds : Int
  mut closes : Int
  mut alive : Bool
  mut browser : String?
}

///|
impl BoardWebServer for FakeBoardServer with fn bind(self) {
  if !self.backend_installed {
    return Err("board backend not installed")
  }
  self.binds += 1
  @async.sleep(10)
  self.alive = true
  self.browser = Some("http://127.0.0.1:18080/?token=test-only")
  Ok({ host: "127.0.0.1", port: 18080, })
}

///|
impl BoardWebServer for FakeBoardServer with fn run(_self) {
  Ok(())
}

///|
impl BoardWebServer for FakeBoardServer with fn browser_url(self) {
  self.browser
}

///|
impl BoardWebServer for FakeBoardServer with fn close(self) {
  if self.alive {
    self.closes += 1
  }
  self.alive = false
  self.browser = None
}

///|
impl BoardWebServer for FakeBoardServer with fn is_alive(self) {
  self.alive
}

///|
impl BoardWebServer for FakeBoardServer with fn last_error(_self) {
  None
}

///|
impl BoardWebServer for FakeBoardServer with fn set_backend(
  self,
  _backend : @backend.BoardBackend,
) {
  self.backend_installed = true
}

///|
priv struct FakeBrowserOpener {
  opened : Array[String]
}

///|
impl BrowserOpener for FakeBrowserOpener with fn open(self, url) {
  self.opened.push(url)
  Ok(())
}

///|
fn lifecycle_server() -> FakeBoardServer {
  {
    backend_installed: false,
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
}

///|
fn lifecycle_opener() -> FakeBrowserOpener {
  { opened: [], }
}

///|
/// Standard create wire command; the backend owns `at_ms`, so it is never
/// sent.
fn wire_create(
  command_id : String,
  id : String,
  rev : Int64,
) -> @protocol.BoardClientCommand {
  {
    command_id,
    name: "board.task.create",
    expected_revision: rev,
    args: {
      "id": id,
      "title": "task \{id}",
      "description": "",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    },
  }
}

///|
async test "attach serves the headless backend with zero binds and opens" {
  let server = lifecycle_server()
  let opener = lifecycle_opener()
  let runtime = BoardRuntime::with_adapters(
    backend=@backend.BoardBackend::BoardBackend(),
    server~,
    opener~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    // No presentation lifecycle ran, but the headless control plane is
    // fully served through the runtime's backend accessor.
    assert_eq(server.binds, 0)
    assert_eq(opener.opened.length(), 0)
    assert_eq(runtime.status(), Stopped)
    let accepted = runtime
      .backend()
      .handle_command(wire_create("headless-1", "t1", 0L))
    assert_eq(accepted.accepted, true)
    assert_eq(accepted.current_revision, Some(1L))
    let frame = runtime.backend().bootstrap_snapshot().unwrap()
    assert_eq(frame.last_seq, 1L)
    assert_eq(frame.board_revision, 1L)
    let client = runtime.backend().subscribe(1L, true)
    assert_eq(client.plan, Live)
    runtime.backend().unsubscribe(client)
    let tick = runtime
      .backend()
      .publish_telemetry(
        board_revision=0L,
        kind="runtime.warning",
        payload=Json::null(),
      )
    assert_eq(tick.seq, 2L)
    assert_eq(runtime.backend().subscriber_count(), 0)
    runtime.shutdown()
  })
}

///|
async test "ensure_server is idempotent under concurrent opens" {
  let server = lifecycle_server()
  let opener = lifecycle_opener()
  let runtime = BoardRuntime::with_adapters(
    backend=@backend.BoardBackend::BoardBackend(),
    server~,
    opener~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    let results = @async.all([
      () => runtime.open_board(),
      () => runtime.open_board(),
    ])
    assert_eq(results.length(), 2)
    assert_true(results[0] is Ok(_))
    assert_true(results[1] is Ok(_))
    assert_eq(server.binds, 1)
    assert_eq(opener.opened.length(), 2)
    runtime.close_server()
    assert_eq(server.closes, 1)
    // close_server never shuts the backend down: headless service continues.
    assert_true(
      runtime.backend().handle_command(wire_create("after-close", "t1", 0L)).accepted,
    )
    runtime.shutdown()
  })
}

///|
async test "ensure_server installs the backend before bind" {
  let server = lifecycle_server()
  let opener = lifecycle_opener()
  let runtime = BoardRuntime::with_adapters(
    backend=@backend.BoardBackend::BoardBackend(),
    server~,
    opener~,
  )
  // The fake refuses to bind without an installed backend, so a successful
  // bind is proof that the runtime ran set_backend first.
  assert_true(BoardWebServer::bind(server) is Err(_))
  assert_eq(server.binds, 0)
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_false(server.backend_installed)
    assert_true(runtime.ensure_server() is Ok(_))
    assert_true(server.backend_installed)
    assert_eq(server.binds, 1)
    runtime.shutdown()
  })
}

///|
async test "close is idempotent and later open rebinds" {
  let server = lifecycle_server()
  let opener = lifecycle_opener()
  let runtime = BoardRuntime::with_adapters(
    backend=@backend.BoardBackend::BoardBackend(),
    server~,
    opener~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.ensure_server() is Ok(_))
    runtime.close_server()
    runtime.close_server()
    assert_eq(server.closes, 1)
    assert_true(runtime.ensure_server() is Ok(_))
    assert_eq(server.binds, 2)
    runtime.shutdown()
  })
}

///|
async test "server start requires host task-group ownership" {
  let server = lifecycle_server()
  let opener = lifecycle_opener()
  let runtime = BoardRuntime::with_adapters(
    backend=@backend.BoardBackend::BoardBackend(),
    server~,
    opener~,
  )
  match runtime.ensure_server() {
    Err(message) => assert_true(message.contains("attach"))
    Ok(_) => fail("unattached runtime must not create an orphan server")
  }
  assert_eq(server.binds, 0)
}

///|
/// Server whose run resists cancellation briefly, so a shutdown's
/// settle_server_task bounded wait is long enough to park in deterministically.
priv struct SlowStopServer {
  mut backend_installed : Bool
  mut closes : Int
  mut alive : Bool
}

///|
impl BoardWebServer for SlowStopServer with fn bind(self) {
  if !self.backend_installed {
    return Err("board backend not installed")
  }
  self.alive = true
  Ok({ host: "127.0.0.1", port: 18081, })
}

///|
impl BoardWebServer for SlowStopServer with fn run(_self) {
  let _ = @async.protect_from_cancel(() => @async.sleep(200))
  Ok(())
}

///|
impl BoardWebServer for SlowStopServer with fn browser_url(_self) {
  None
}

///|
impl BoardWebServer for SlowStopServer with fn close(self) {
  if self.alive {
    self.closes += 1
  }
  self.alive = false
}

///|
impl BoardWebServer for SlowStopServer with fn is_alive(self) {
  self.alive
}

///|
impl BoardWebServer for SlowStopServer with fn last_error(_self) {
  None
}

///|
impl BoardWebServer for SlowStopServer with fn set_backend(
  self,
  _backend : @backend.BoardBackend,
) {
  self.backend_installed = true
}

///|
async test "runtime shutdown cleanup completes even when cancelled" {
  let server : SlowStopServer = {
    backend_installed: false,
    closes: 0,
    alive: false,
  }
  let opener = lifecycle_opener()
  let runtime = BoardRuntime::with_adapters(
    backend=@backend.BoardBackend::BoardBackend(),
    server~,
    opener~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(
      runtime.backend().handle_command(wire_create("t1", "t1", 0L)).accepted,
    )
    assert_true(runtime.ensure_server() is Ok(_))
    let task = group.spawn(() => runtime.shutdown())
    // Cancel while the teardown is parked in settle_server_task's bounded
    // wait (the fake run resists cancellation for 200ms): the protected
    // cleanup must still close the listener and shut the backend down.
    @async.sleep(10)
    task.cancel()
    let _ = task.wait() catch { _ => () }
    assert_eq(server.closes, 1)
    assert_false(server.alive)
    let closed = runtime.backend().handle_command(wire_create("t2", "t2", 1L))
    assert_false(closed.accepted)
    assert_eq(closed.error, Some("board_unavailable"))
    assert_eq(closed.current_revision, None)
    assert_eq(
      runtime.backend().bootstrap_snapshot(),
      Err("snapshot_unavailable"),
    )
    runtime.shutdown()
  })
}
