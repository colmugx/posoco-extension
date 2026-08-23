///|
/// One scripted `nmem` CLI outcome keyed by subcommand ("context" / "wm"):
/// tests address attempts by what they ask for, not by the full argv, so a
/// host environment variable (NMEM_SPACE, NMEM_PLUGIN_SOURCE_APP, ...) cannot
/// change which reply a test hits.
priv struct FakeRunner {
  replies : Map[String, CliOutcome]
  home_files : Map[String, String]
  mut timeout_calls : Int
  calls : Array[Array[String]]
  home_reads : Array[String]
}

///|
fn FakeRunner::FakeRunner(
  replies? : Map[String, CliOutcome] = Map::from_array([]),
  home_files? : Map[String, String] = Map::from_array([]),
  timeout_calls? : Int = 0,
) -> FakeRunner {
  { replies, home_files, timeout_calls, calls: [], home_reads: [] }
}

///|
fn fake_cli_key(args : Array[String]) -> String {
  if args.contains("context") {
    return "context"
  }
  if args.contains("wm") {
    return "wm"
  }
  // Memory/thread commands key by the subcommand after the scope token
  // ("m add" → "m:add"), so one fake can answer each surface separately.
  for i, arg in args {
    if arg == "m" || arg == "t" {
      let sub = if i + 1 < args.length() { args[i + 1] } else { "" }
      return "\{arg}:\{sub}"
    }
  }
  if args.contains("status") {
    "status"
  } else {
    "other"
  }
}

///|
impl NmemRunner for FakeRunner with fn run_cli(
  self : FakeRunner,
  args : Array[String],
  timeout_ms~ : Int,
) -> CliOutcome {
  ignore(timeout_ms)
  self.calls.push(args.copy())
  if self.timeout_calls > 0 {
    self.timeout_calls = self.timeout_calls - 1
    return { exit: NMEM_CLI_ABORT_EXIT, stdout: "", stderr: "timeout" }
  }
  match self.replies.get(fake_cli_key(args)) {
    Some(outcome) => outcome
    None => { exit: 1, stdout: "", stderr: "not scripted" }
  }
}

///|
impl NmemRunner for FakeRunner with fn read_home_file(
  self : FakeRunner,
  rel : String,
) -> String? {
  self.home_reads.push(rel)
  self.home_files.get(rel)
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
  { requests: [], remote_total: 0 }
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
        hooks=[ext as &@posoco.Hook],
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
async test "e2e: startup context and guidance land in the system prompt" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        {
          exit: 0,
          stdout: "{\"rendered_markdown\":\"# Owner Rules\\nBe terse.\",\"markdown\":\"unused\"}",
          stderr: "",
        },
      ),
    ]),
  )
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let agent = nmem_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  assert_true(model.received_messages.length() > 0)
  let prompt = first_system_text(model.received_messages[0])
  assert_true(prompt.contains("## Nowledge Mem Context Bundle"))
  assert_true(prompt.contains("# Owner Rules"))
  assert_true(prompt.contains("Be terse."))
  assert_true(prompt.contains("## Nowledge Mem Guidance"))
  assert_true(prompt.contains("search"))
}

///|
async test "e2e: completed turns sync create then incremental append" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        { exit: 0, stdout: "{\"rendered_markdown\":\"ctx\"}", stderr: "" },
      ),
    ]),
  )
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem::new(source_app="posoco", transport~, runner~)
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
async test "e2e: degraded startup injects the unavailable notice" {
  let runner = FakeRunner::FakeRunner()
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let agent = nmem_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  let prompt = first_system_text(model.received_messages[0])
  assert_true(prompt.contains("## Nowledge Mem Context Bundle"))
  assert_true(prompt.contains("unavailable"))
  assert_true(prompt.contains("## Nowledge Mem Guidance"))
}

///|
async test "attach runs the flusher loop inside a host task group" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        { exit: 0, stdout: "{\"rendered_markdown\":\"ctx\"}", stderr: "" },
      ),
    ]),
  )
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem::new(source_app="posoco", transport~, runner~)
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
async test "on_shutdown stops the flusher and drains pending lanes" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        { exit: 0, stdout: "{\"rendered_markdown\":\"ctx\"}", stderr: "" },
      ),
    ]),
  )
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem::new(source_app="posoco", transport~, runner~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
  ])
  let agent = nmem_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  @posoco.Lifecycle::on_shutdown(ext)
  inspect(transport.requests.length(), content="1")
  inspect(ext.engine.stopped, content="true")
}

///|
test "on_event_at: TurnFailed stages a turn_failed sync request" {
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner=FakeRunner::FakeRunner(),
  )
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
  ignore(@posoco.Hook::before_model(ext, snapshot))
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
test "on_event_at: ModelResponseReceived completes the snapshot deduplicated" {
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner=FakeRunner::FakeRunner(),
  )
  ext.config = Some(lane_config())
  let snapshot : Array[@posoco.Message] = [@posoco.tk_user_msg("hello")]
  ignore(@posoco.Hook::before_model(ext, snapshot))
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
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        { exit: 0, stdout: "{\"rendered_markdown\":\"ctx\"}", stderr: "" },
      ),
    ]),
  )
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem::new(source_app="posoco", transport~, runner~)
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
test "assemble_prompt_sections: context bundle then guidance" {
  let sections = assemble_prompt_sections(
    { context: Some("bundle text"), degraded_reason: None },
    "posoco",
  )
  assert_true(
    sections.has_prefix("## Nowledge Mem Context Bundle\n\nbundle text"),
  )
  assert_true(sections.contains("## Nowledge Mem Guidance"))
}

///|
test "assemble_prompt_sections: degraded notice under the bundle header" {
  let sections = assemble_prompt_sections(
    { context: None, degraded_reason: Some(STARTUP_CONTEXT_FAILED) },
    "posoco",
  )
  assert_true(sections.contains("## Nowledge Mem Context Bundle"))
  assert_true(
    sections.contains(
      "[Nowledge Mem startup context unavailable: startup context reads failed.]",
    ),
  )
  assert_true(sections.contains("## Nowledge Mem Guidance"))
}

///|
test "assemble_prompt_sections: empty startup yields guidance only" {
  let sections = assemble_prompt_sections(
    { context: None, degraded_reason: None },
    "posoco",
  )
  assert_false(sections.contains("Context Bundle"))
  assert_true(sections.has_prefix("## Nowledge Mem Guidance"))
}

///|
async test "read_startup_context: context bundle wins on the first attempt" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        {
          exit: 0,
          stdout: "{\"rendered_markdown\":\"ctx\",\"markdown\":\"shadowed\"}",
          stderr: "",
        },
      ),
      ("wm", { exit: 0, stdout: "{\"content\":\"wm\"}", stderr: "" }),
    ]),
  )
  let startup = read_startup_context(runner, lane_config())
  guard startup.context is Some(context) else { fail("expected a context") }
  inspect(context, content="ctx")
  inspect(startup.degraded_reason is None, content="true")
  inspect(runner.calls.length(), content="1")
}

///|
async test "read_startup_context: wm read after context fails" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("context", { exit: 1, stdout: "", stderr: "boom" }),
      (
        "wm",
        {
          exit: 0,
          stdout: "{\"content\":\"wm text\",\"exists\":true}",
          stderr: "",
        },
      ),
    ]),
  )
  let startup = read_startup_context(runner, lane_config())
  guard startup.context is Some(context) else { fail("expected a context") }
  inspect(context, content="wm text")
  inspect(runner.calls.length(), content="2")
}

///|
async test "read_startup_context: local memory file after CLI misses" {
  let runner = FakeRunner::FakeRunner(
    home_files=Map::from_array([("ai-now/memory.md", "local notes")]),
  )
  let startup = read_startup_context(runner, lane_config())
  guard startup.context is Some("local notes") else {
    fail("expected the local fallback content")
  }
  inspect(startup.degraded_reason is None, content="true")
}

///|
async test "read_startup_context: everything fails reports degraded reads" {
  let runner = FakeRunner::FakeRunner()
  let startup = read_startup_context(runner, lane_config())
  inspect(startup.context is None, content="true")
  guard startup.degraded_reason is Some(reason) else {
    fail("expected a degraded reason")
  }
  inspect(reason, content=STARTUP_CONTEXT_FAILED)
}

///|
async test "read_startup_context: timeouts report the timeout reason" {
  let runner = FakeRunner::FakeRunner(timeout_calls=10)
  let startup = read_startup_context(runner, lane_config())
  inspect(startup.context is None, content="true")
  guard startup.degraded_reason is Some(reason) else {
    fail("expected a degraded reason")
  }
  inspect(reason, content=STARTUP_CONTEXT_TIMED_OUT)
}

///|
async test "read_startup_context: configured space scopes the first attempt" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        { exit: 0, stdout: "{\"rendered_markdown\":\"scoped\"}", stderr: "" },
      ),
    ]),
  )
  let startup = read_startup_context(runner, lane_config(space=Some("team")))
  guard startup.context is Some("scoped") else { fail("expected a context") }
  inspect(runner.calls.length(), content="1")
  let first = runner.calls[0]
  assert_true(first.contains("--source-app"))
  assert_true(first.contains("--space"))
  assert_true(first.contains("team"))
}

///|
async test "read_startup_context: remote service never reads the local file" {
  let runner = FakeRunner::FakeRunner(
    home_files=Map::from_array([("ai-now/memory.md", "local notes")]),
  )
  let startup = read_startup_context(
    runner,
    lane_config(api_url="https://mem.example.com"),
  )
  inspect(startup.context is None, content="true")
  inspect(runner.home_reads.length(), content="0")
}

///|
test "truncate_startup_context: oversized bundles carry the tail note" {
  let oversized = String::from_array(Array::make(20001, 'a'))
  let truncated = truncate_startup_context(oversized, "cetas")
  let note = context_truncation_note("cetas")
  inspect(truncated.length(), content="\{20000 + 2 + note.length()}")
  assert_true(truncated.contains(note))
  assert_true(note.contains("Cetas"))
}

///|
test "truncate_startup_context: bundles at the cap pass through" {
  let exact = String::from_array(Array::make(20000, 'a'))
  inspect(truncate_startup_context(exact, "cetas") == exact, content="true")
}
