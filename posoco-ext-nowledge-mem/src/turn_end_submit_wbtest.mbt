///|
// Blind-zone tests for the turn-end commit (plan D3, 2026-08-23 revision):
// real hosts pass no task group and never call on_shutdown, so NOTHING in
// this file may call flush_pending or attach — run_turn returning must be
// the only commit trigger.

///|
/// Agent wiring for the blind-zone cases: the memory port declared is what
/// attaches core's MemoryRetrievalHook, mirroring the e2e conventions.
fn turn_end_agent(
  ext : NowledgeMem,
  model : @posoco.ScriptedModel,
  tools? : Array[&@posoco.ToolProvider] = [],
) -> @posoco.Agent raise {
  @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(id="tools", tools~),
      @posoco.tk_ext(
        id="nowledge_mem",
        memory=[ext as &@posoco.MemoryPort],
        observers=[ext as &@posoco.Observer],
        hooks=[ext as &@posoco.PipelineHook],
        lifecycle=[ext as &@posoco.Lifecycle],
        prompt_contributors=[ext as &@posoco.SystemPromptContributor],
      ),
      @posoco.tk_ext(
        id="io",
        sessions=[@posoco.RecordingSessionStore::RecordingSessionStore()],
        observers=[@posoco.RecordingObserver::RecordingObserver()],
      ),
    ],
    config=@posoco.tk_config(),
  )
}

///|
/// Core acceptance: once run_turn returns — with no flush_pending, no attach,
/// no shutdown — the create POST has already reached the transport and the
/// memory queue is empty.
async test "turn_end: completed turn commits the create before run_turn returns" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
      ("m:-n", { exit: 0, stdout: "{\"memories\":[]}", stderr: "" }),
    ]),
  )
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem(source_app="posoco", transport~, runner~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
  ])
  let agent = turn_end_agent(ext, model)
  let result = agent.run_turn(@posoco.tk_user_msg("hello"), "session_1")
  inspect(result.final_session_id, content="session_1")
  inspect(transport.requests.length(), content="1")
  guard ext.config is Some(config) else { fail("config was not resolved") }
  let (url, body) = transport.requests[0]
  assert_true(url.has_suffix("/threads"))
  assert_false(url.contains("append"))
  inspect(
    body_thread_id(body),
    content=thread_id(config.source_app, "session_1"),
  )
  inspect(body_messages(body).length(), content="2")
  match json_field(body, "source") {
    Some(Json::String(source)) =>
      inspect(source == config.source_app, content="true")
    _ => fail("create body should carry a string source")
  }
  inspect(ext.mem.queue.length(), content="0")
}

///|
/// The second turn commits an incremental append by itself: only the new
/// user/assistant pair rides the append body.
async test "turn_end: second turn commits only the incremental append" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
      ("m:-n", { exit: 0, stdout: "{\"memories\":[]}", stderr: "" }),
    ]),
  )
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem(source_app="posoco", transport~, runner~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let agent = turn_end_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  inspect(transport.requests.length(), content="1")
  ignore(agent.run_turn(@posoco.tk_user_msg("more"), "session_1"))
  inspect(transport.requests.length(), content="2")
  guard ext.config is Some(config) else { fail("config was not resolved") }
  let (url, body) = transport.requests[1]
  assert_true(
    url.has_suffix(
      "/threads/" + thread_id(config.source_app, "session_1") + "/append",
    ),
  )
  inspect(body_messages(body).length(), content="2")
}

///|
/// The failed path commits too: run_turn raises on the scripted model error,
/// yet the turn-2 submission (carrying the new user message) still reached
/// the transport before the raise escaped.
async test "turn_end: failed turn still commits before run_turn raises" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
      ("m:-n", { exit: 0, stdout: "{\"memories\":[]}", stderr: "" }),
    ]),
  )
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem(source_app="posoco", transport~, runner~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
    @posoco.ScriptedModelStep::Fail(@posoco.ModelError::Transport("boom")),
  ])
  let agent = turn_end_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  inspect(transport.requests.length(), content="1")
  try agent.run_turn(@posoco.tk_user_msg("more"), "session_1") catch {
    @posoco.AgentError::Model(_) => ()
    _ => fail("expected the scripted model failure to raise")
  } noraise {
    _ => fail("expected the failed-script turn to raise")
  }
  inspect(transport.requests.length(), content="2")
  guard ext.config is Some(config) else { fail("config was not resolved") }
  let (url, body) = transport.requests[1]
  assert_true(
    url.has_suffix(
      "/threads/" + thread_id(config.source_app, "session_1") + "/append",
    ),
  )
  // The failed turn's snapshot still carries its new user message.
  inspect(body.stringify().contains("more"), content="true")
}

///|
/// Queued memory writes ride the same turn-end drain: after run_turn
/// returns, the `m add` already ran against the CLI and the queue is empty.
async test "turn_end: queued memory write drains before run_turn returns" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
      ("m:add", { exit: 0, stdout: "{\"id\":\"mem_7\"}", stderr: "" }),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  ignore(
    @posoco.MemoryPort::store(ext, {
      id: "",
      content: "deploy fridays only",
      metadata: Map::from_array([]),
      score: None,
    }),
  )
  inspect(ext.mem.queue.length(), content="1")
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let agent = turn_end_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  inspect(ext.mem.queue.length(), content="0")
  inspect(
    runner.calls.filter(fn(args) { args.contains("add") }).length(),
    content="1",
  )
}

///|
/// Transport whose appends sleep `hang_ms` before answering, modelling a
/// wedged server; creates answer instantly so turn 1 can establish the lane.
priv struct HangingAppendTransport {
  requests : Array[(String, Json)]
  mut hang_ms : Int
}

///|
fn HangingAppendTransport::HangingAppendTransport() -> HangingAppendTransport {
  { requests: [], hang_ms: 0 }
}

///|
impl NmemTransport for HangingAppendTransport with fn post_json(
  self : HangingAppendTransport,
  url : String,
  _headers : Map[String, String],
  body : Json,
  timeout_ms~ : Int,
) -> Result[NmemResponse, String] {
  ignore(timeout_ms)
  self.requests.push((url, body))
  let count = body_messages(body).length()
  if url.has_suffix("/threads") {
    Ok({
      status: 200,
      body: j(
        "{\"thread\":{\"thread_id\":\"\{body_thread_id(body)}\",\"message_count\":\{count}}}",
      ),
    })
  } else {
    if self.hang_ms > 0 {
      @async.sleep(self.hang_ms)
    }
    Ok({
      status: 200,
      body: j(
        "{\"success\":true,\"messages_added\":\{count},\"total_messages\":\{count}}",
      ),
    })
  }
}

///|
/// The drain is bounded and silent: with the sync budget far below the
/// transport hang, run_turn still returns without raising, roughly within
/// the budget, and the timeout lands in the lane's `last_error`. The resolve
/// chain floors NMEM_SYNC_TIMEOUT_MS at 1s, so the sub-second budget is
/// injected through the field the drain reads (white-box).
async test "turn_end: drain timeout is bounded and stays silent" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
      ("m:-n", { exit: 0, stdout: "{\"memories\":[]}", stderr: "" }),
    ]),
  )
  let transport = HangingAppendTransport::HangingAppendTransport()
  let ext = NowledgeMem(source_app="posoco", transport~, runner~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let agent = turn_end_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  inspect(transport.requests.length(), content="1")
  ext.timeout_ms = 200
  transport.hang_ms = 1000
  let started = @async.now()
  ignore(agent.run_turn(@posoco.tk_user_msg("more"), "session_1"))
  let elapsed = @async.now() - started
  inspect(transport.requests.length(), content="2")
  // 200ms budget vs 1000ms hang: far below the hang, above the budget.
  assert_true(elapsed < 900L)
  guard ext.config is Some(config) else { fail("config was not resolved") }
  let lane_key = sync_lane_key(
    thread_id(config.source_app, "session_1"),
    config,
  )
  guard ext.engine.lane_state(lane_key) is Some(lane) else {
    fail("expected the session lane")
  }
  guard lane.last_error is Some(_) else {
    fail("expected the timeout recorded on the lane")
  }
}

///|
/// Echo transport that also logs every POST into a shared sequence log, so
/// drain timing is assertable relative to tool executions.
priv struct LoggingEchoTransport {
  requests : Array[(String, Json)]
  log : Array[String]
  mut remote_total : Int
}

///|
fn LoggingEchoTransport::LoggingEchoTransport(
  log : Array[String],
) -> LoggingEchoTransport {
  { requests: [], log, remote_total: 0 }
}

///|
impl NmemTransport for LoggingEchoTransport with fn post_json(
  self : LoggingEchoTransport,
  url : String,
  _headers : Map[String, String],
  body : Json,
  timeout_ms~ : Int,
) -> Result[NmemResponse, String] {
  ignore(timeout_ms)
  self.requests.push((url, body))
  let count = body_messages(body).length()
  if url.has_suffix("/threads") {
    self.log.push("post:create:" + body_thread_id(body))
    self.remote_total = count
    Ok({
      status: 200,
      body: j(
        "{\"thread\":{\"thread_id\":\"\{body_thread_id(body)}\",\"message_count\":\{count}}}",
      ),
    })
  } else {
    self.log.push("post:append")
    self.remote_total = self.remote_total + count
    let mode = if json_field(body, "expected_message_count") is Some(_) {
      ",\"append_mode\":\"checkpointed\""
    } else {
      ""
    }
    Ok({
      status: 200,
      body: j(
        "{\"success\":true,\"messages_added\":\{count},\"total_messages\":\{self.remote_total}\{mode}}",
      ),
    })
  }
}

///|
/// Tool provider that only records its execution into the shared log.
priv struct LogToolProvider {
  log : Array[String]
}

///|
impl @posoco.ToolProvider for LogToolProvider with fn list_tools(
  self : LogToolProvider,
) -> Array[@posoco.ToolDef] {
  ignore(self)
  [@posoco.tk_tool_def("probe", "records execution order")]
}

///|
impl @posoco.ToolProvider for LogToolProvider with fn execute(
  self : LogToolProvider,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  self.log.push("tool")
  @posoco.tk_ok_result("ok")
}

///|
/// before_tool drains under the 750ms throttle: within the interval after
/// the last drain, tool calls fire no transport POST (turn 2's tool runs
/// before any POST beyond the turn-1 create); once the interval has elapsed
/// (turn 3), the drain fires BEFORE the tool executes. Fresh lanes staged
/// per phase make each drain visible as its own create.
async test "before_tool: mid-turn drain is throttled to one per interval" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
      ("m:-n", { exit: 0, stdout: "{\"memories\":[]}", stderr: "" }),
    ]),
  )
  let log : Array[String] = []
  let transport = LoggingEchoTransport::LoggingEchoTransport(log)
  let ext = NowledgeMem(source_app="posoco", transport~, runner~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("probe", "c1", Json::null()),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("probe", "c2", Json::null()),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("fin")),
  ])
  let agent = turn_end_agent(ext, model, tools=[
    LogToolProvider::{ log, } as &@posoco.ToolProvider,
  ])
  // Turn 1 (no tools): the create commits at turn end.
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  // A fresh lane staged now would surface any before_tool drain as a create.
  ext.stage_session_sync("session_2", "probe")
  // Turn 2 starts within 750ms of turn 1's turn-end drain: the tool runs
  // with NO new POST from before_tool; both staged lanes commit at turn end.
  ignore(agent.run_turn(@posoco.tk_user_msg("probe please"), "session_1"))
  // After the interval elapses, the next before_tool drains first.
  @async.sleep(800)
  ext.stage_session_sync("session_3", "probe")
  ignore(agent.run_turn(@posoco.tk_user_msg("again"), "session_1"))
  debug_inspect(
    log,
    content=(
      #|[
      #|  "post:create:posoco-session_1",
      #|  "tool",
      #|  "post:append",
      #|  "post:create:posoco-session_2",
      #|  "post:create:posoco-session_3",
      #|  "tool",
      #|  "post:append",
      #|]
    ),
  )
}
