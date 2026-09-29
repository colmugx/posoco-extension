///|
priv struct CommandFakeServer {
  mut binds : Int
  mut alive : Bool
}

///|
impl @runtime.BoardWebServer for CommandFakeServer with fn attach_event_hub(
  _self,
  _hub,
) {
  ()
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
test "board extension exposes realtime observer and hook surfaces in s2" {
  let board = BoardExtension::BoardExtension()
  assert_eq(board.extension_id(), "posoco_ext_board")
  let manifest = board.manifest()
  assert_eq(manifest.id, "posoco_ext_board")
  assert_eq(manifest.tools.length(), 0)
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.observers.length(), 1)
  assert_eq(manifest.hooks.length(), 1)
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
        assert_false(Json::object(fields).stringify().contains("test-only"))
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


///|
fn realtime_test_board() -> BoardExtension {
  let server : CommandFakeServer = { binds: 0, alive: false, }
  let opener : CommandFakeOpener = { urls: [], }
  let runtime = @runtime.BoardRuntime::with_adapters(
    event_buffer=16,
    client_queue_depth=4,
    server=server,
    opener=opener,
  )
  BoardExtension::with_runtime(runtime~)
}

///|
fn realtime_test_scope() -> @posoco.EventScope {
  {
    session_id: @posoco.SessionId::unchecked("session-1"),
    run_id: @posoco.RunId::unchecked("run-1"),
    turn_id: @posoco.TurnId::unchecked("turn-1"),
  }
}

///|
test "observer projection preserves scope and never advances board revision" {
  let board = realtime_test_board()
  let scope = realtime_test_scope()
  board.on_event_at(Some(scope), @posoco.TurnEvent::TurnStarted)
  board.on_event_at(
    Some(scope),
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::TextDelta(token="hello"),
    ),
  )
  board.on_event_at(Some(scope), @posoco.TurnEvent::TurnCompleted)
  let events = board.runtime().event_history()
  assert_eq(events.length(), 3)
  assert_eq(events[0].kind, "run.started")
  assert_eq(events[1].kind, "assistant.delta")
  assert_eq(events[2].kind, "run.completed")
  assert_eq(events[0].seq, 1L)
  assert_eq(events[2].seq, 3L)
  for event in events {
    assert_eq(event.board_revision, 0L)
    match event.scope {
      Some(value) => {
        assert_eq(value.session_id, Some("session-1"))
        assert_eq(value.run_id, Some("run-1"))
        assert_eq(value.turn_id, Some("turn-1"))
      }
      None => fail("scoped Posoco event must keep scope")
    }
  }
}

///|
test "observer keeps missing scope null instead of guessing" {
  let board = realtime_test_board()
  board.on_event_at(
    None,
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::ReasoningDelta(token="thinking"),
    ),
  )
  let events = board.runtime().event_history()
  assert_eq(events.length(), 1)
  assert_eq(events[0].kind, "assistant.reasoning_delta")
  assert_true(events[0].scope is None)
}

///|
test "tool projection redacts credential-like lines and terminal stays ordered" {
  let board = realtime_test_board()
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("call-1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object({
      "command": Json::string("printenv"),
      "api_key": Json::string("must-never-project"),
    }),
  }
  board.on_event_at(
    Some(realtime_test_scope()),
    @posoco.TurnEvent::ToolCallPending(call),
  )
  board.on_event_at(
    Some(realtime_test_scope()),
    @posoco.TurnEvent::ToolCallSucceeded(
      call~,
      content="ok\nAuthorization: Bearer top-secret\napi_key=hidden\ndone",
      structured=None,
      attachments=[],
    ),
  )
  board.on_event_at(
    Some(realtime_test_scope()),
    @posoco.TurnEvent::TurnCompleted,
  )
  let events = board.runtime().event_history()
  assert_eq(events.length(), 3)
  assert_eq(events[0].kind, "tool.pending")
  assert_eq(events[1].kind, "tool.completed")
  assert_eq(events[2].kind, "run.completed")
  let wire = events[1].to_json().stringify()
  assert_true(wire.contains("[redacted]"))
  assert_false(wire.contains("top-secret"))
  assert_false(wire.contains("hidden"))
  assert_false(wire.contains("must-never-project"))
  assert_true(events[1].seq < events[2].seq)
}

///|
test "user-request lifecycle maps to blocked and resumed without prompt body" {
  let board = realtime_test_board()
  board.on_event_at(
    Some(realtime_test_scope()),
    @posoco.TurnEvent::UserRequestStarted(
      kind="confirm",
      prompt="Authorization: secret prompt",
    ),
  )
  board.on_event_at(
    Some(realtime_test_scope()),
    @posoco.TurnEvent::UserRequestFinished(kind="confirm", outcome="answered"),
  )
  let events = board.runtime().event_history()
  assert_eq(events[0].kind, "run.blocked")
  assert_eq(events[1].kind, "run.resumed")
  assert_false(events[0].to_json().stringify().contains("secret prompt"))
}
