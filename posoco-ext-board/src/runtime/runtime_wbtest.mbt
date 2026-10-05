///|
priv struct FakeBoardServer {
  mut binds : Int
  mut closes : Int
  mut alive : Bool
  mut browser : String?
}

///|
impl BoardWebServer for FakeBoardServer with fn bind(self) {
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
priv struct FakeBrowserOpener {
  opened : Array[String]
}

///|
impl BrowserOpener for FakeBrowserOpener with fn open(self, url) {
  self.opened.push(url)
  Ok(())
}

///|
test "event hub mints monotonic seq" {
  let hub = BoardEventHub::BoardEventHub(capacity=8)
  let first = hub.publish(
    board_revision=0L,
    kind="turn.started",
    payload=Json::null(),
  )
  let second = hub.publish(
    board_revision=0L,
    kind="assistant.delta",
    payload=Json::string("x"),
  )
  assert_eq(first.seq, 1L)
  assert_eq(second.seq, 2L)
  assert_eq(hub.current_seq(), 2L)
}

///|
test "event seq advances independently from board revision" {
  let hub = BoardEventHub::BoardEventHub(capacity=8)
  let a = hub.publish(
    board_revision=7L,
    kind="assistant.delta",
    payload=Json::string("a"),
  )
  let b = hub.publish(
    board_revision=7L,
    kind="assistant.delta",
    payload=Json::string("b"),
  )
  let c = hub.publish(
    board_revision=8L,
    kind="task.transitioned",
    payload=Json::null(),
  )
  assert_eq(a.seq, 1L)
  assert_eq(b.seq, 2L)
  assert_eq(c.seq, 3L)
  assert_eq(a.board_revision, 7L)
  assert_eq(b.board_revision, 7L)
  assert_eq(c.board_revision, 8L)
}

///|
test "event hub evicts oldest events at capacity" {
  let hub = BoardEventHub::BoardEventHub(capacity=2)
  for i in 0..<3 {
    let _ = hub.publish(
      board_revision=0L,
      kind="tick",
      payload=Json::number(i.to_double()),
    )
  }
  let history = hub.history()
  assert_eq(history.length(), 2)
  assert_eq(history[0].seq, 2L)
  assert_eq(history[1].seq, 3L)
  let replay = hub.history_since(2L)
  assert_eq(replay.length(), 1)
  assert_eq(replay[0].seq, 3L)
}

///|
async test "ensure_server is idempotent under concurrent opens" {
  let server : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(server~, opener~)
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
  })
}

///|
async test "close is idempotent and later open rebinds" {
  let server : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(server~, opener~)
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
  let server : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(server~, opener~)
  match runtime.ensure_server() {
    Err(message) => assert_true(message.contains("attach"))
    Ok(_) => fail("unattached runtime must not create an orphan server")
  }
  assert_eq(server.binds, 0)
}

///|
fn runtime_create(id : String, rev : Int64) -> @domain.BoardCommand {
  @domain.BoardCommand::CreateTask(
    id=@domain.BoardTaskId::BoardTaskId(id),
    title="task \{id}",
    description="",
    priority=@domain.Normal,
    definition_of_done=[],
    dependencies=[],
    at_ms=1000L,
    expected_revision=rev,
  )
}

///|
async test "runtime owns one coordinator and telemetry stays independent" {
  let server : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(server~, opener~)
  // Before attach the domain is unreachable, like the server worker.
  assert_true(
    runtime.coordinator.submit(command=runtime_create("t1", 0L))
    is Err(NotAttached),
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    // Loading is asynchronous; readiness gates every domain API use.
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    let events = runtime.coordinator.submit(command=runtime_create("t1", 0L))
    assert_eq(events.unwrap().length(), 1)
    assert_eq(runtime.coordinator.revision().unwrap(), 1L)
    // Repeated attach is idempotent for the coordinator too.
    runtime.attach(group)
    let _ = runtime.coordinator.submit(command=runtime_create("t2", 1L))
    assert_eq(runtime.coordinator.revision().unwrap(), 2L)
    // Domain revision and telemetry seq are fully independent counters.
    assert_eq(runtime.current_seq(), 0L)
    let event = runtime.publish_telemetry(
      board_revision=0L,
      kind="tick",
      payload=Json::null(),
    )
    assert_eq(event.seq, 1L)
    assert_eq(runtime.coordinator.revision().unwrap(), 2L)
    let _ = runtime.coordinator.submit(command=runtime_create("t3", 2L))
    assert_eq(runtime.current_seq(), 1L)
    assert_eq(runtime.coordinator.revision().unwrap(), 3L)
    runtime.shutdown()
  })
  // Shutdown closes coordinator admission...
  assert_true(runtime.coordinator.revision() is Err(Closed))
  assert_true(
    runtime.coordinator.submit(command=runtime_create("t4", 3L)) is Err(Closed),
  )
  // ...and a fresh attach restores the runtime's durable board instead of
  // starting over: three committed tasks, no fabricated revision reset.
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    assert_eq(runtime.coordinator.revision().unwrap(), 3L)
    assert_eq(runtime.coordinator.tasks().unwrap().length(), 3)
    let _ = runtime.coordinator.submit(command=runtime_create("t4", 3L))
    assert_eq(runtime.coordinator.revision().unwrap(), 4L)
    runtime.shutdown()
  })
}

///|
/// Server whose run resists cancellation briefly, so a shutdown's
/// settle_server_task bounded wait is long enough to park in deterministically.
priv struct SlowStopServer {
  mut closes : Int
  mut alive : Bool
}

///|
impl BoardWebServer for SlowStopServer with fn bind(self) {
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
async test "runtime shutdown cleanup completes even when cancelled" {
  let server : SlowStopServer = { closes: 0, alive: false, }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(server~, opener~)
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    let _ = runtime.coordinator.submit(command=runtime_create("t1", 0L))
    assert_true(runtime.ensure_server() is Ok(_))
    let task = group.spawn(() => runtime.shutdown())
    // Cancel while the teardown is parked in settle_server_task's bounded
    // wait (the fake run resists cancellation for 200ms): the protected
    // cleanup must still close the listener and shut the coordinator down.
    @async.sleep(10)
    task.cancel()
    let _ = task.wait() catch { _ => () }
    assert_eq(server.closes, 1)
    assert_false(server.alive)
    assert_true(runtime.coordinator.revision() is Err(Closed))
    assert_true(
      runtime.coordinator.submit(command=runtime_create("t2", 1L))
      is Err(Closed),
    )
  })
}

///|
/// Seed one committed board through the same codec the coordinator restores
/// from. Lives in the runtime tests because the domain package cannot import
/// the store package without a dependency cycle.
async fn durable_seed() -> &@store.BoardStore {
  let store : &@store.BoardStore = @store.MemoryBoardStore::MemoryBoardStore()
  let created = @domain.BoardDomain::propose(
    @domain.BoardState::BoardState(),
    runtime_create("durable", 0L),
  ).unwrap()
  let snapshot = created.next_state.snapshot()
  // The domain accepts exactly what the storage codec accepts.
  let decoded = @store.decode_snapshot(
    @store.encode_snapshot(snapshot).unwrap(),
  ).unwrap()
  assert_eq(decoded, snapshot)
  assert_true(@domain.BoardState::from_snapshot(decoded) is Ok(_))
  assert_eq(store.persist(snapshot, created.events), Ok(()))
  store
}

///|
async test "runtime loading restores its own store and stays isolated" {
  let durable = durable_seed()
  let server_a : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener_a : FakeBrowserOpener = { opened: [], }
  let server_b : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener_b : FakeBrowserOpener = { opened: [], }
  let restoring = BoardRuntime::with_adapters(
    server=server_a,
    opener=opener_a,
    store=durable,
  )
  let isolated = BoardRuntime::with_adapters(server=server_b, opener=opener_b)
  @async.with_task_group(group => {
    restoring.attach(group)
    isolated.attach(group)
    assert_true(restoring.coordinator.wait_ready() is Ok(_))
    assert_true(isolated.coordinator.wait_ready() is Ok(_))
    // Each runtime loaded only its own store.
    assert_eq(restoring.coordinator.revision().unwrap(), 1L)
    assert_eq(restoring.coordinator.tasks().unwrap().length(), 1)
    assert_eq(isolated.coordinator.revision().unwrap(), 0L)
    assert_eq(isolated.coordinator.tasks().unwrap().length(), 0)
    // Mutations stay inside their own runtime's board.
    let _ = restoring.coordinator.submit(command=runtime_create("next", 1L))
    assert_eq(restoring.coordinator.revision().unwrap(), 2L)
    assert_eq(isolated.coordinator.revision().unwrap(), 0L)
    let _ = isolated.coordinator.submit(command=runtime_create("t1", 0L))
    assert_eq(isolated.coordinator.revision().unwrap(), 1L)
    // Only the restoring runtime's commits reached the durable store.
    let loaded = durable.load().unwrap().snapshot
    assert_eq(loaded.revision, 2L)
    assert_eq(loaded.tasks.length(), 2)
    restoring.shutdown()
    isolated.shutdown()
  })
}
