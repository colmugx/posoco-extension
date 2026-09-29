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
  mut opened : Array[String]
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
  let runtime = BoardRuntime::with_adapters(server=server, opener=opener)
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
  let runtime = BoardRuntime::with_adapters(server=server, opener=opener)
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
  let runtime = BoardRuntime::with_adapters(server=server, opener=opener)
  match runtime.ensure_server() {
    Err(message) => assert_true(message.contains("attach"))
    Ok(_) => fail("unattached runtime must not create an orphan server")
  }
  assert_eq(server.binds, 0)
}
