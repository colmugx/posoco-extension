///|
test "commands: /memory and /nmem declare positional actions" {
  let ext = tool_ext()
  let defs = @posoco.CommandPort::commands(ext)
  inspect(defs.length(), content="2")
  let def = defs[0]
  inspect(def.id, content="memory")
  inspect(def.ctype is @posoco.CommandType::Action, content="true")
  inspect(def.params.length(), content="1")
  inspect(def.params[0].name, content="action")
  inspect(def.params[0].positional, content="true")
  inspect(def.shortcut is None, content="true")
  inspect(def.params[0].choices is Some(["status", "flush"]), content="true")
  let nmem = defs[1]
  inspect(nmem.id, content="nmem")
  inspect(
    nmem.params[0].choices is Some(["status", "url", "mcp"]),
    content="true",
  )
  inspect(nmem.params[1].name, content="value")
  // The manifest carries one command port view; both defs come from it.
  let manifest_commands = @posoco.Extension::manifest(ext).commands
  inspect(manifest_commands.length(), content="1")
  inspect(manifest_commands[0].commands().length(), content="2")
}

///|
async test "/nmem status: channels, mode, identity, probe" {
  let ext = tool_ext()
  let outcome = @posoco.CommandPort::invoke(ext, "nmem", Json::null())
  guard outcome is @posoco.CommandOutcome::Success(feedback~, structured~, ..) else {
    fail("expected success")
  }
  assert_true(feedback.contains("tools: mcp http://127.0.0.1:14242/mcp"))
  assert_true(feedback.contains("sync: http://127.0.0.1:14242 (local)"))
  assert_true(feedback.contains("mcp: connected"))
  assert_true(feedback.contains("identity: source_app=posoco"))
  assert_false(feedback.contains("cli"))
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "tool_channel") is Some(Json::String("mcp")),
    content="true",
  )
  inspect(
    json_field(payload, "mode") is Some(Json::String("local")),
    content="true",
  )
  inspect(json_field(payload, "connected") is Some(Json::True), content="true")
  // A remote base reads as remote.
  let cloud = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    mcp=FakeNmemMcp::FakeNmemMcp(),
    platform=FakePlatform::FakePlatform(),
  )
  cloud.config = Some(
    lane_config(
      api_url="https://mem.example.com",
      mcp_url="https://mem.example.com/mcp",
    ),
  )
  let remote = @posoco.CommandPort::invoke(cloud, "nmem", Json::null())
  guard remote is @posoco.CommandOutcome::Success(feedback=remote_feedback, ..) else {
    fail("expected success")
  }
  assert_true(remote_feedback.contains("(remote)"))
  assert_true(
    remote_feedback.contains("tools: mcp https://mem.example.com/mcp"),
  )
}

///|
async test "/nmem url: switches api base, re-derives mcp, flushes, persists" {
  let transport = EchoNmemTransport::EchoNmemTransport()
  let mcp = FakeNmemMcp::FakeNmemMcp()
  let platform = FakePlatform::FakePlatform(
    home_files=Map::from_array([
      (".nowledge-mem/config.json", "{\"space\": \"team\"}"),
    ]),
  )
  let ext = NowledgeMem(source_app="posoco", transport~, mcp~, platform~)
  ext.config = Some(lane_config(space=Some("team")))
  // Stage a sync so the pre-switch flush is observable.
  let scope : @posoco.EventScope = {
    session_id: @posoco.SessionId::unchecked("s1"),
    run_id: @posoco.RunId::unchecked("r1"),
    turn_id: @posoco.TurnId::unchecked("t1"),
  }
  @posoco.Observer::on_event_at(
    ext,
    Some(scope),
    @posoco.TurnEvent::TurnStarted,
  )
  ignore(
    @posoco.PipelineHook::before_model(ext, [
      @posoco.tk_user_msg("hi"),
      assistant_msg("hello"),
    ]),
  )
  @posoco.Observer::on_event_at(
    ext,
    Some(scope),
    @posoco.TurnEvent::TurnCompleted,
  )
  inspect(transport.requests.length(), content="0")
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "nmem",
    Json::string("url https://mem.example.com/"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, ..) else {
    fail("expected success")
  }
  // The staged sync flushed to the OLD address before the switch.
  inspect(transport.requests.length(), content="1")
  assert_true(transport.requests[0].0.has_prefix("http://127.0.0.1:14242"))
  // Config updated: api base + derived mcp endpoint, other fields kept.
  guard ext.config is Some(config) else { fail("config was dropped") }
  inspect(config.api_url, content="https://mem.example.com")
  inspect(config.mcp_url, content="https://mem.example.com/mcp")
  inspect(config.space is Some("team"), content="true")
  // The lazy client got the new endpoint.
  guard mcp.configured is Some((url, _, name)) else {
    fail("expected the client to be reconfigured")
  }
  inspect(url, content="https://mem.example.com/mcp")
  inspect(name, content="posoco")
  assert_true(feedback.contains("api base switched to https://mem.example.com"))
  assert_true(feedback.contains("persisted"))
  // Persistence preserved the sibling key and wrote the camelCase spelling.
  inspect(platform.writes.length(), content="1")
  let (rel, content) = platform.writes[0]
  inspect(rel, content=".nowledge-mem/config.json")
  let written = j(content)
  inspect(
    json_field(written, "apiUrl")
    is Some(Json::String("https://mem.example.com")),
    content="true",
  )
  inspect(
    json_field(written, "space") is Some(Json::String("team")),
    content="true",
  )
}

///|
async test "/nmem url: snake_case config spelling is preserved" {
  let platform = FakePlatform::FakePlatform(
    home_files=Map::from_array([
      (".nowledge-mem/config.json", "{\"api_url\": \"http://old.example.com\"}"),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    mcp=FakeNmemMcp::FakeNmemMcp(),
    platform~,
  )
  ext.config = Some(lane_config())
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "nmem",
    j("{\"action\": \"url\", \"value\": \"https://mem.example.com\"}"),
  )
  guard outcome is @posoco.CommandOutcome::Success(..) else {
    fail("expected success")
  }
  let written = j(platform.writes[0].1)
  // The file already used api_url; the update keeps that spelling.
  inspect(
    json_field(written, "api_url")
    is Some(Json::String("https://mem.example.com")),
    content="true",
  )
  inspect(json_field(written, "apiUrl") is None, content="true")
}

///|
async test "/nmem url: a malformed config file is refused, the switch still applies" {
  let platform = FakePlatform::FakePlatform(
    home_files=Map::from_array([(".nowledge-mem/config.json", "{ not json")]),
  )
  let mcp = FakeNmemMcp::FakeNmemMcp()
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    mcp~,
    platform~,
  )
  ext.config = Some(lane_config())
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "nmem",
    Json::string("url https://mem.example.com"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, ..) else {
    fail("expected success")
  }
  guard ext.config is Some(config) else { fail("config was dropped") }
  inspect(config.api_url, content="https://mem.example.com")
  inspect(platform.writes.length(), content="0")
  assert_true(feedback.contains("warning: persist failed"))
  assert_true(feedback.contains("refusing to overwrite"))
}

///|
async test "/nmem url: a write failure degrades to a runtime-only switch" {
  let platform = FakePlatform::FakePlatform(write_error=Some("disk full"))
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    mcp=FakeNmemMcp::FakeNmemMcp(),
    platform~,
  )
  ext.config = Some(lane_config())
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "nmem",
    Json::string("url https://mem.example.com"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, ..) else {
    fail("expected success")
  }
  guard ext.config is Some(config) else { fail("config was dropped") }
  inspect(config.api_url, content="https://mem.example.com")
  assert_true(feedback.contains("warning: persist failed (disk full)"))
  assert_true(feedback.contains("lasts until shutdown"))
}

///|
async test "/nmem mcp: overrides only the mcp endpoint" {
  let mcp = FakeNmemMcp::FakeNmemMcp()
  let platform = FakePlatform::FakePlatform()
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    mcp~,
    platform~,
  )
  ext.config = Some(lane_config())
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "nmem",
    Json::string("mcp https://proxy.example.com/mcp"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, ..) else {
    fail("expected success")
  }
  guard ext.config is Some(config) else { fail("config was dropped") }
  inspect(config.api_url, content="http://127.0.0.1:14242")
  inspect(config.mcp_url, content="https://proxy.example.com/mcp")
  guard mcp.configured is Some((url, _, _)) else {
    fail("expected the client to be reconfigured")
  }
  inspect(url, content="https://proxy.example.com/mcp")
  let written = j(platform.writes[0].1)
  inspect(
    json_field(written, "mcpUrl")
    is Some(Json::String("https://proxy.example.com/mcp")),
    content="true",
  )
  assert_true(feedback.contains("mcp endpoint switched"))
}

///|
async test "/nmem: malformed invocations fail with usage" {
  let ext = tool_ext()
  let missing = @posoco.CommandPort::invoke(ext, "nmem", Json::string("url"))
  guard missing is @posoco.CommandOutcome::Failure(reason~) else {
    fail("expected failure")
  }
  assert_true(reason.contains("need a URL argument"))
  let bad = @posoco.CommandPort::invoke(
    ext,
    "nmem",
    Json::string("url ftp://nope"),
  )
  guard bad is @posoco.CommandOutcome::Failure(reason=bad_reason) else {
    fail("expected failure")
  }
  assert_true(bad_reason.contains("not an http(s) URL"))
  let unknown = @posoco.CommandPort::invoke(
    ext,
    "nmem",
    Json::string("vaporize"),
  )
  guard unknown is @posoco.CommandOutcome::Failure(reason=unknown_reason) else {
    fail("expected failure")
  }
  assert_true(unknown_reason.contains("unknown /nmem action 'vaporize'"))
  try @posoco.CommandPort::invoke(ext, "nmem_vaporize", Json::null()) catch {
    @posoco.CommandError::NotFound(_) => ()
    _ => fail("expected NotFound")
  } noraise {
    _ => fail("expected invoke to raise")
  }
}

///|
async test "/memory status: connectivity, lanes, queue, and the passive-read gate" {
  let ext = tool_ext(
    mcp=FakeNmemMcp::FakeNmemMcp(
      script=Map::from_array([
        ("read_working_memory", mcp_ok("{\"exists\":false}")),
      ]),
    ),
  )
  // One dirty lane, one queued write, one spent passive-read gate.
  let scope : @posoco.EventScope = {
    session_id: @posoco.SessionId::unchecked("s1"),
    run_id: @posoco.RunId::unchecked("r1"),
    turn_id: @posoco.TurnId::unchecked("t1"),
  }
  @posoco.Observer::on_event_at(
    ext,
    Some(scope),
    @posoco.TurnEvent::TurnStarted,
  )
  ignore(
    @posoco.PipelineHook::before_model(ext, [
      @posoco.tk_user_msg("hi"),
      assistant_msg("hello"),
    ]),
  )
  @posoco.Observer::on_event_at(
    ext,
    Some(scope),
    @posoco.TurnEvent::TurnCompleted,
  )
  ignore(
    @posoco.MemoryPort::store(ext, mem_entry(id="", content="queued note")),
  )
  ignore(@posoco.MemoryPort::search(ext, mem_query(query="anchor query")))
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("status"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, structured~, ..) else {
    fail("expected success")
  }
  assert_true(feedback.contains("nowledge-mem: connected"))
  assert_true(feedback.contains("posoco-s1"))
  assert_true(feedback.contains("acknowledged=0"))
  assert_true(feedback.contains("pending=true"))
  assert_true(feedback.contains("last_error=none"))
  assert_true(feedback.contains("memory queue: 1 pending write"))
  assert_true(feedback.contains("passive read: done"))
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "nmem_connected") is Some(Json::True),
    content="true",
  )
  guard json_field(payload, "lanes") is Some(Json::Array(lanes)) else {
    fail("expected a lanes array")
  }
  inspect(lanes.length(), content="1")
  inspect(
    json_field(lanes[0], "thread_id") is Some(Json::String("posoco-s1")),
    content="true",
  )
  inspect(json_field(lanes[0], "pending") is Some(Json::True), content="true")
  guard json_field(payload, "queue_depth")
    is Some(Json::Number(queue_depth, ..)) else {
    fail("expected queue_depth")
  }
  inspect(queue_depth == 1.0, content="true")
  inspect(
    json_field(payload, "passive_read_done") is Some(Json::True),
    content="true",
  )
}

///|
async test "/memory status: an unspent gate reports pending" {
  let ext = tool_ext()
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("status"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, structured~, ..) else {
    fail("expected success")
  }
  assert_true(feedback.contains("passive read: pending"))
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "passive_read_done") is Some(Json::False),
    content="true",
  )
}

///|
async test "/memory status: an unreachable server reports it and still lists state" {
  let ext = tool_ext(
    mcp=FakeNmemMcp::FakeNmemMcp(
      probe_result=Err("nowledge-mem mcp connect failed: refused"),
    ),
  )
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "memory",
    j("{\"action\":\"status\"}"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, structured~, ..) else {
    fail("expected success")
  }
  assert_true(feedback.contains("nowledge-mem: unreachable"))
  assert_true(feedback.contains("refused"))
  assert_true(feedback.contains("thread lanes: none yet"))
  assert_true(feedback.contains("memory queue: 0 pending write"))
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "nmem_connected") is Some(Json::False),
    content="true",
  )
}

///|
async test "/memory flush drains staged lanes and the write queue" {
  let ext = tool_ext(
    mcp=FakeNmemMcp::FakeNmemMcp(
      script=Map::from_array([("memory_add", mcp_ok("{\"id\":\"mem_7\"}"))]),
    ),
  )
  ignore(@posoco.MemoryPort::store(ext, mem_entry(id="", content="note")))
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("flush"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, structured~, ..) else {
    fail("expected success")
  }
  assert_true(feedback.contains("write queue empty"))
  inspect(ext.mem.queue.length(), content="0")
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "lanes_attempted") is Some(Json::Number(0.0, ..)),
    content="true",
  )
  inspect(
    json_field(payload, "queue_remaining") is Some(Json::Number(0.0, ..)),
    content="true",
  )
  // A failed write keeps the write queued and says so.
  let fail_ext = tool_ext(
    mcp=FakeNmemMcp::FakeNmemMcp(
      script=Map::from_array([("memory_add", FakeMcpEntry::Fail("boom"))]),
    ),
  )
  ignore(
    @posoco.MemoryPort::store(fail_ext, mem_entry(id="", content="doomed")),
  )
  let failed = @posoco.CommandPort::invoke(
    fail_ext,
    "memory",
    Json::string("flush"),
  )
  guard failed is @posoco.CommandOutcome::Success(feedback=failed_feedback, ..) else {
    fail("expected success")
  }
  assert_true(failed_feedback.contains("1 write(s) still queued"))
  inspect(fail_ext.mem.queue.length(), content="1")
}

///|
async test "/memory with no action or an unknown action returns usage" {
  let ext = tool_ext()
  let bare = @posoco.CommandPort::invoke(ext, "memory", Json::null())
  guard bare is @posoco.CommandOutcome::Success(feedback=bare_feedback, ..) else {
    fail("expected success")
  }
  assert_true(bare_feedback.contains("/memory status"))
  assert_true(bare_feedback.contains("/memory flush"))
  assert_false(bare_feedback.contains("/memory refresh"))
  // An empty {action} object reads as no action.
  let empty_obj = @posoco.CommandPort::invoke(
    ext,
    "memory",
    j("{\"action\":\"\"}"),
  )
  guard empty_obj is @posoco.CommandOutcome::Success(feedback=obj_feedback, ..) else {
    fail("expected success")
  }
  inspect(obj_feedback == bare_feedback, content="true")
  let unknown = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("vaporize"),
  )
  guard unknown is @posoco.CommandOutcome::Failure(reason~) else {
    fail("expected failure")
  }
  assert_true(reason.contains("unknown /memory action 'vaporize'"))
  assert_true(reason.contains("/memory status"))
  // The removed refresh subcommand is now an unknown action.
  let refresh = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("refresh"),
  )
  guard refresh is @posoco.CommandOutcome::Failure(reason~) else {
    fail("expected failure")
  }
  assert_true(reason.contains("unknown /memory action 'refresh'"))
}

///|
async test "/memory invoke with a foreign id raises CommandError::NotFound" {
  let ext = tool_ext()
  try @posoco.CommandPort::invoke(ext, "memory_vaporize", Json::null()) catch {
    @posoco.CommandError::NotFound(_) => ()
    _ => fail("expected NotFound")
  } noraise {
    _ => fail("expected invoke to raise")
  }
}
