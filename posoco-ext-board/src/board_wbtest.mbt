///|
priv struct CommandFakeServer {
  mut binds : Int
  mut alive : Bool
}

///|
impl @runtime.BoardWebServer for CommandFakeServer with fn bind(self) {
  self.binds += 1
  self.alive = true
  Ok({ host: "127.0.0.1", port: 19090, })
}

///|
impl @runtime.BoardWebServer for CommandFakeServer with fn run(_self) {
  Ok(())
}

///|
impl @runtime.BoardWebServer for CommandFakeServer with fn browser_url(self) {
  if self.alive {
    Some("http://127.0.0.1:19090/?token=test-only")
  } else {
    None
  }
}

///|
impl @runtime.BoardWebServer for CommandFakeServer with fn close(self) {
  self.alive = false
}

///|
impl @runtime.BoardWebServer for CommandFakeServer with fn is_alive(self) {
  self.alive
}

///|
impl @runtime.BoardWebServer for CommandFakeServer with fn last_error(_self) {
  None
}

///|
priv struct CommandFakeOpener {
  urls : Array[String]
}

///|
impl @runtime.BrowserOpener for CommandFakeOpener with fn open(self, url) {
  self.urls.push(url)
  Ok(())
}

///|
test "board extension exposes only command and lifecycle surfaces in s1" {
  let board = BoardExtension::BoardExtension()
  assert_eq(board.extension_id(), "posoco_ext_board")
  let manifest = board.manifest()
  assert_eq(manifest.id, "posoco_ext_board")
  assert_eq(manifest.tools.length(), 0)
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.observers.length(), 0)
  assert_eq(manifest.hooks.length(), 0)
  assert_eq(manifest.lifecycle.length(), 1)
  assert_eq(manifest.requires.length(), 0)
  let defs = board.commands()
  assert_eq(defs.length(), 3)
  assert_eq(defs[0].id, "board.open")
  assert_true(defs[0].aliases.contains("board"))
  assert_eq(defs[1].id, "board.status")
  assert_eq(defs[2].id, "board.close")
}

///|
test "board config exposes localhost-safe defaults" {
  let config = BoardConfig::BoardConfig()
  assert_false(config.auto_start)
  assert_false(config.auto_open)
  assert_eq(config.bind_host, "127.0.0.1")
  assert_eq(config.event_buffer, 4096)
  assert_eq(config.client_queue_depth, 256)
}

///|
async test "board command opens reuses and closes one runtime" {
  let server : CommandFakeServer = { binds: 0, alive: false, }
  let opener : CommandFakeOpener = { urls: [], }
  let runtime = @runtime.BoardRuntime::with_adapters(
    server=server,
    opener=opener,
  )
  let board = BoardExtension::with_runtime(runtime~)
  @async.with_task_group(group => {
    board.attach(group)
    let first = board.invoke("board.open", Json::null())
    let second = board.invoke("board", Json::null())
    assert_true(first is Success(..))
    assert_true(second is Success(..))
    assert_eq(server.binds, 1)
    assert_eq(opener.urls.length(), 2)

    let status = board.invoke("board.status", Json::null())
    match status {
      Success(structured=Some(Json::Object(fields)), ..) => {
        assert_eq(fields.get("state"), Some(Json::string("running")))
        assert_false(structured.stringify().contains("test-only"))
      }
      _ => fail("expected structured running status")
    }

    let closed = board.invoke("board.close", Json::null())
    assert_true(closed is Success(..))
    assert_false(server.alive)
    board.runtime().shutdown()
  })
}

///|
async test "board open fails clearly before runtime attach" {
  let server : CommandFakeServer = { binds: 0, alive: false, }
  let opener : CommandFakeOpener = { urls: [], }
  let runtime = @runtime.BoardRuntime::with_adapters(
    server=server,
    opener=opener,
  )
  let board = BoardExtension::with_runtime(runtime~)
  match board.invoke("board.open", Json::null()) {
    Failure(reason~) => assert_true(reason.contains("attach"))
    _ => fail("unattached /board must fail instead of orphaning a server")
  }
}
