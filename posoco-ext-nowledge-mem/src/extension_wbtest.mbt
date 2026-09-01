///|
/// Platform fake: scripted home files (the config-file source), recording
/// every read.
priv struct FakePlatform {
  home_files : Map[String, String]
  home_reads : Array[String]
  writes : Array[(String, String)]
  write_error : String?
}

///|
fn FakePlatform::FakePlatform(
  home_files? : Map[String, String] = Map::from_array([]),
  write_error? : String? = None,
) -> FakePlatform {
  { home_files, home_reads: [], writes: [], write_error, }
}

///|
impl NmemPlatform for FakePlatform with fn read_home_file(
  self : FakePlatform,
  rel : String,
) -> String? {
  self.home_reads.push(rel)
  self.home_files.get(rel)
}

///|
impl NmemPlatform for FakePlatform with fn write_home_file(
  self : FakePlatform,
  rel : String,
  content : String,
) -> Result[Unit, String] {
  match self.write_error {
    Some(message) => Err(message)
    None => {
      self.writes.push((rel, content))
      Ok(())
    }
  }
}

///|
/// One scripted MCP reply keyed by tool name. `Fail` scripts a
/// transport-level failure; `Reply` scripts the server's answer (text and
/// its own error flag).
priv enum FakeMcpEntry {
  Reply(McpCallOutcome)
  Fail(String)
}

///|
/// A clean server reply carrying `text`.
fn mcp_ok(text : String) -> FakeMcpEntry {
  FakeMcpEntry::Reply({ is_error: false, text, })
}

///|
/// A server reply whose own error flag is set, carrying `text`.
fn mcp_server_error(text : String) -> FakeMcpEntry {
  FakeMcpEntry::Reply({ is_error: true, text, })
}

///|
/// MCP fake: records every call as (tool, args-json-text) and answers from
/// a per-tool script; a tool without an entry is a loud "not scripted"
/// failure so a drifted surface cannot pass silently.
priv struct FakeNmemMcp {
  script : Map[String, FakeMcpEntry]
  probe_result : Result[String, String]
  mut configured : (String, String?, String)?
  calls : Array[(String, String)]
  mut probes : Int
  mut shutdowns : Int
}

///|
fn FakeNmemMcp::FakeNmemMcp(
  script? : Map[String, FakeMcpEntry] = Map::from_array([]),
  probe_result? : Result[String, String] = Ok("nowledge-mem 0.10.72, 64 tools"),
) -> FakeNmemMcp {
  {
    script,
    probe_result,
    configured: None,
    calls: [],
    probes: 0,
    shutdowns: 0,
  }
}

///|
impl NmemMcp for FakeNmemMcp with fn configure(
  self : FakeNmemMcp,
  url~ : String,
  auth_token~ : String?,
  name~ : String,
) -> Unit {
  self.configured = Some((url, auth_token, name))
}

///|
impl NmemMcp for FakeNmemMcp with fn call_tool(
  self : FakeNmemMcp,
  tool : String,
  args : Json,
  timeout_ms~ : Int,
) -> Result[McpCallOutcome, String] {
  ignore(timeout_ms)
  self.calls.push((tool, args.stringify()))
  match self.script.get(tool) {
    Some(FakeMcpEntry::Reply(outcome)) => Ok(outcome)
    Some(FakeMcpEntry::Fail(message)) => Err(message)
    None => Err("no script for '\{tool}'")
  }
}

///|
impl NmemMcp for FakeNmemMcp with fn probe(
  self : FakeNmemMcp,
  timeout_ms~ : Int,
) -> Result[String, String] {
  ignore(timeout_ms)
  self.probes = self.probes + 1
  self.probe_result
}

///|
impl NmemMcp for FakeNmemMcp with fn shutdown(self : FakeNmemMcp) -> Unit {
  self.shutdowns = self.shutdowns + 1
}

///|
/// Parsed arguments of recorded call `index` (the fake stores the args as
/// JSON text; tests read fields instead of matching on key order).
fn recorded_args(fake : FakeNmemMcp, index : Int) -> Json {
  j(fake.calls[index].1)
}

///|
/// How many calls went to one tool.
fn call_count(fake : FakeNmemMcp, tool : String) -> Int {
  let mut count = 0
  for call in fake.calls {
    if call.0 == tool {
      count = count + 1
    }
  }
  count
}

///|
/// Extension over the test fakes: echo transport, scripted MCP, scripted
/// home files.
fn nmem_ext(
  transport? : &NmemTransport = EchoNmemTransport::EchoNmemTransport(),
  mcp? : &NmemMcp = FakeNmemMcp::FakeNmemMcp(),
  platform? : &NmemPlatform = FakePlatform::FakePlatform(),
) -> NowledgeMem {
  NowledgeMem(source_app="posoco", transport~, mcp~, platform~)
}

///|
/// Transport fake that acknowledges whatever it is asked for: creates echo
/// the requested thread id and message count, appends report success with
/// running totals and the checkpoint mode the request asked for. Robust to
/// any env-derived source_app because the ack follows the request.
priv struct EchoNmemTransport {
  requests : Array[(String, Json)]
  mut remote_total : Int
}

///|
fn EchoNmemTransport::EchoNmemTransport() -> EchoNmemTransport {
  { requests: [], remote_total: 0, }
}

///|
fn body_thread_id(body : Json) -> String {
  match body {
    Json::Object(fields) =>
      match fields.get("thread_id") {
        Some(Json::String(id)) => id
        _ => ""
      }
    _ => ""
  }
}

///|
fn body_messages(body : Json) -> Array[Json] {
  match body {
    Json::Object(fields) =>
      match fields.get("messages") {
        Some(Json::Array(items)) => items
        _ => []
      }
    _ => []
  }
}

///|
impl NmemTransport for EchoNmemTransport with fn post_json(
  self : EchoNmemTransport,
  url : String,
  _headers : Map[String, String],
  body : Json,
  timeout_ms~ : Int,
) -> Result[NmemResponse, String] {
  ignore(timeout_ms)
  self.requests.push((url, body))
  let count = body_messages(body).length()
  if url.has_suffix("/threads") {
    self.remote_total = count
    Ok({
      status: 200,
      body: j(
        "{\"thread\":{\"thread_id\":\"\{body_thread_id(body)}\",\"message_count\":\{count}}}",
      ),
    })
  } else {
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
fn assistant_msg(text : String) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
/// Text of the aggregated system message the model received (call index,
/// message index 0 — the SystemPromptHook injection point).
fn first_system_text(messages : Array[@posoco.Message]) -> String {
  match messages[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] => text
        _ => ""
      }
    _ => ""
  }
}

///|
fn nmem_agent(
  ext : NowledgeMem,
  model : @posoco.ScriptedModel,
) -> @posoco.Agent raise {
  @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(
        id="nowledge_mem",
        observers=[ext as &@posoco.Observer],
        hooks=[ext as &@posoco.PipelineHook],
        memory=[ext as &@posoco.MemoryPort],
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
/// The system-prompt contribution is instructions only: guidance lands,
/// recalled data never does (it travels the core-injected memory message —
/// see inbound_e2e_wbtest).
async test "e2e: the system prompt carries guidance only, never data" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_working_memory", mcp_ok("{\"exists\":false}")),
    ]),
  )
  let ext = nmem_ext(mcp~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let agent = nmem_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  assert_true(model.received_messages.length() > 0)
  let messages = model.received_messages[0]
  let prompt = first_system_text(messages)
  assert_true(prompt.contains("## Nowledge Mem Guidance"))
  assert_true(prompt.contains("search"))
  assert_false(prompt.contains("## Nowledge Mem Context Bundle"))
  assert_false(prompt.contains("# Owner Rules"))
  // The one MCP call is the session's inbound working-memory read, and with
  // empty working memory no memory message reaches the payload.
  inspect(mcp.calls.length(), content="1")
  inspect(injected_memory_count(messages), content="0")
}

///|
async test "on_start configures the mcp client with the resolved endpoint" {
  let platform = FakePlatform::FakePlatform(
    home_files=Map::from_array([
      (
        ".nowledge-mem/config.json", "{\"apiUrl\": \"http://mem.test\", \"apiKey\": \"file-key\"}",
      ),
    ]),
  )
  let mcp = FakeNmemMcp::FakeNmemMcp()
  let ext = nmem_ext(mcp~, platform~)
  @posoco.Lifecycle::on_start(ext)
  guard mcp.configured is Some((url, auth_token, name)) else {
    fail("expected the client to be configured")
  }
  inspect(url, content="http://mem.test/mcp")
  debug_inspect(auth_token, content="Some(\"file-key\")")
  inspect(name, content="posoco")
  guard ext.config is Some(config) else { fail("config was not resolved") }
  inspect(config.mcp_url, content="http://mem.test/mcp")
}

///|
async test "e2e: completed turns sync create then incremental append" {
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = nmem_ext(transport~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let agent = nmem_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  ext.flush_pending()
  inspect(transport.requests.length(), content="1")
  guard ext.config is Some(config) else { fail("config was not resolved") }
  let expected_thread = thread_id(config.source_app, "session_1")
  let (create_url, create_body) = transport.requests[0]
  assert_true(create_url.has_suffix("/threads"))
  assert_false(create_url.contains("append"))
  inspect(body_thread_id(create_body) == expected_thread, content="true")
  inspect(body_messages(create_body).length(), content="2")
  match json_field(create_body, "source") {
    Some(Json::String(source)) =>
      inspect(source == config.source_app, content="true")
    _ => fail("create body should carry a string source")
  }
  ignore(agent.run_turn(@posoco.tk_user_msg("more"), "session_1"))
  ext.flush_pending()
  inspect(transport.requests.length(), content="2")
  let (append_url, append_body) = transport.requests[1]
  assert_true(append_url.has_suffix("/threads/" + expected_thread + "/append"))
  inspect(body_messages(append_body).length(), content="2")
  inspect(
    json_field(append_body, "deduplicate") is Some(Json::True),
    content="true",
  )
}

///|
async test "attach runs the flusher loop inside a host task group" {
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = nmem_ext(transport~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
  ])
  let agent = nmem_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  @async.with_task_group(group => {
    ext.attach(group)
    // One flusher interval: the loop drains the staged create on its own,
    // with no explicit flush_pending call.
    @async.sleep(1100)
    ext.engine.stop()
  })
  inspect(transport.requests.length(), content="1")
  assert_true(transport.requests[0].0.has_suffix("/threads"))
}

///|
/// Cancellation regression for the attach-level loop (cetas-acp stdin EOF):
/// the aborting host body fails the group and run_flusher is cancelled
/// mid-sleep; the loop must re-raise so the teardown completes instead of
/// spinning the idle loop forever. The with_timeout watchdog bounds the
/// assertion; `stopped` staying false proves the exit came from
/// cancellation, not stop().
async test "attach: flusher loop terminates on task group cancellation" {
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = nmem_ext(transport~)
  let outcome : Result[Unit, Error] = Ok(
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        ext.attach(group)
        @async.sleep(20)
        raise HostEof
      })
    }),
  ) catch {
    error => Err(error)
  }
  guard outcome is Err(error) else {
    fail("expected the host abort to propagate out of the group")
  }
  assert_true(error is HostEof)
  inspect(ext.engine.stopped, content="false")
  inspect(transport.requests.length(), content="0")
}

///|
async test "on_shutdown stops the flusher, drains pending lanes, closes mcp" {
  let mcp = FakeNmemMcp::FakeNmemMcp()
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = nmem_ext(transport~, mcp~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
  ])
  let agent = nmem_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  @posoco.Lifecycle::on_shutdown(ext)
  inspect(transport.requests.length(), content="1")
  inspect(ext.engine.stopped, content="true")
  inspect(mcp.shutdowns, content="1")
}

///|
async test "on_event_at: TurnFailed stages a turn_failed sync request" {
  let ext = nmem_ext()
  ext.config = Some(lane_config())
  let scope : @posoco.EventScope = {
    session_id: @posoco.SessionId::unchecked("s9"),
    run_id: @posoco.RunId::unchecked("r1"),
    turn_id: @posoco.TurnId::unchecked("t1"),
  }
  @posoco.Observer::on_event_at(
    ext,
    Some(scope),
    @posoco.TurnEvent::TurnStarted,
  )
  let snapshot : Array[@posoco.Message] = [
    @posoco.tk_user_msg("hello"),
    assistant_msg("hi"),
  ]
  ignore(@posoco.PipelineHook::before_model(ext, snapshot))
  @posoco.Observer::on_event_at(
    ext,
    Some(scope),
    @posoco.TurnEvent::TurnFailed("model down"),
  )
  let lane_key = sync_lane_key(thread_id("posoco", "s9"), lane_config())
  guard ext.engine.lane_state(lane_key) is Some(lane) else {
    fail("expected a dirty lane")
  }
  guard lane.pending is Some(request) else {
    fail("expected a pending request")
  }
  inspect(request.sync_reason, content="turn_failed")
  inspect(request.thread_id, content="posoco-s9")
}

///|
async test "on_event_at: ModelResponseReceived completes the snapshot deduplicated" {
  let ext = nmem_ext()
  ext.config = Some(lane_config())
  let snapshot : Array[@posoco.Message] = [@posoco.tk_user_msg("hello")]
  ignore(@posoco.PipelineHook::before_model(ext, snapshot))
  @posoco.Observer::on_event_at(
    ext,
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=assistant_msg("hi"),
      usage=None,
    ),
  )
  @posoco.Observer::on_event_at(
    ext,
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=assistant_msg("hi"),
      usage=None,
    ),
  )
  inspect(ext.transcript.length(), content="2")
  guard ext.transcript[1] is @posoco.Message::AssistantMessage(..) else {
    fail("expected the assistant reply appended")
  }
}

///|
async test "on_event_at: SessionRedirect stages the old lane and switches the session" {
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = nmem_ext(transport~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let agent = nmem_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  guard ext.config is Some(config) else { fail("config was not resolved") }
  // A manual redirect: the snapshot is staged under the OLD session id with
  // the redirect reason (best effort — the observer slot cannot flush), and
  // current_session follows the target.
  @posoco.Observer::on_event_at(
    ext,
    None,
    @posoco.TurnEvent::SessionRedirect(
      from="session_1",
      to="session_2",
      messages_before=2,
      messages_after=2,
    ),
  )
  inspect(ext.current_session is Some("session_2"), content="true")
  let old_lane_key = sync_lane_key(
    thread_id(config.source_app, "session_1"),
    config,
  )
  guard ext.engine.lane_state(old_lane_key) is Some(lane) else {
    fail("expected the old session's lane")
  }
  guard lane.pending is Some(request) else {
    fail("expected a pending session_redirect sync")
  }
  inspect(request.sync_reason, content="session_redirect")
  inspect(request.session_id, content="session_1")
  // The next turn syncs into the NEW session's lane.
  ignore(agent.run_turn(@posoco.tk_user_msg("more"), "session_2"))
  ext.flush_pending()
  inspect(transport.requests.length(), content="2")
  inspect(
    body_thread_id(transport.requests[0].1),
    content=thread_id(config.source_app, "session_1"),
  )
  inspect(
    body_thread_id(transport.requests[1].1),
    content=thread_id(config.source_app, "session_2"),
  )
}

///|
test "truncate_context: oversized payloads carry the tail note" {
  let oversized = String::from_array(Array::make(20001, 'a'))
  let truncated = truncate_context(oversized, "cetas")
  let note = context_truncation_note("cetas")
  inspect(truncated.length(), content="\{20000 + 2 + note.length()}")
  assert_true(truncated.contains(note))
  assert_true(note.contains("Cetas"))
}

///|
test "truncate_context: payloads at the cap pass through" {
  let exact = String::from_array(Array::make(20000, 'a'))
  inspect(truncate_context(exact, "cetas") == exact, content="true")
}
