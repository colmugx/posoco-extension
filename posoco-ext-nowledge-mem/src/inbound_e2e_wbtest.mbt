///|
/// How many read_working_memory calls the MCP fake saw.
fn wm_read_call_count(mcp : FakeNmemMcp) -> Int {
  call_count(mcp, "read_working_memory")
}

///|
/// Agent wiring for the e2e cases: the extension contributes its ports
/// directly — the memory declaration is what hands core the session-opening
/// inbound injection and the built-in memory tools.
fn mem_agent(
  ext : NowledgeMem,
  model : @posoco.ScriptedModel,
) -> @posoco.Agent raise {
  mem_agent_store(
    ext,
    model,
    @posoco.RecordingSessionStore::RecordingSessionStore(),
  )
}

///|
/// Same wiring over a caller-owned session store — the resume case builds a
/// second extension and agent on the same store.
fn mem_agent_store(
  ext : NowledgeMem,
  model : @posoco.ScriptedModel,
  store : @posoco.RecordingSessionStore,
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
      @posoco.tk_ext(id="io", sessions=[store], observers=[
        @posoco.RecordingObserver::RecordingObserver(),
      ]),
    ],
    config=@posoco.tk_config(),
  )
}

///|
/// e2e A: the session's one working-memory read lands as ONE user-role
/// memory message, positioned before the real first user input.
async test "e2e A: first-turn inbound lands as a memory message before the real user input" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      (
        "read_working_memory",
        mcp_ok(
          "{\"exists\":true,\"content\":\"Ship the zephyr widget via the staging pipeline\"}",
        ),
      ),
    ]),
  )
  let ext = nmem_ext(mcp~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let agent = mem_agent(ext, model)
  ignore(
    agent.run_turn(
      @posoco.tk_user_msg("how do I ship the zephyr widget"),
      "session_1",
    ),
  )
  inspect(model.received_messages.length() > 0, content="true")
  let messages = model.received_messages[0]
  guard injected_memory_text(messages) is Some(injected) else {
    fail("expected an injected memory message")
  }
  assert_true(injected.contains("## Memory"))
  assert_true(
    injected.contains("Ship the zephyr widget via the staging pipeline"),
  )
  // Position: the memory message sits directly after the assembled system
  // prompt, and the real user input follows it.
  inspect(injected_memory_count(messages), content="1")
  inspect(injected_memory_text([messages[1]]) is Some(_), content="true")
  guard messages[2] is @posoco.Message::UserMessage(content~) &&
    content is [@posoco.Content::Text(real_input), ..] else {
    fail("expected the real user input after the injected memory message")
  }
  inspect(real_input, content="how do I ship the zephyr widget")
  inspect(wm_read_call_count(mcp), content="1")
}

///|
/// e2e: a tool round-trip means two model calls in one turn — the second
/// call does not re-read, and the frozen memory message persists verbatim
/// in both payloads.
async test "e2e: same-turn second model call does not re-read and keeps the injection" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      (
        "read_working_memory",
        mcp_ok("{\"exists\":true,\"content\":\"answer with beta flags\"}"),
      ),
    ]),
  )
  let ext = nmem_ext(mcp~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response(
        "noop",
        "c1",
        Json::object(Map::from_array([])),
      ),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let tools = @posoco.RecordingToolProvider(
    [@posoco.tk_tool_def("noop", "no-op")],
    Map::from_array([
      (
        "noop",
        @posoco.ScriptedToolOutcome::OutcomeOk(@posoco.tk_ok_result("ok")),
      ),
    ]),
  )
  let agent = @posoco.Agent(
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
      @posoco.tk_ext(id="tools", tools=[tools]),
      @posoco.tk_ext(
        id="io",
        sessions=[@posoco.RecordingSessionStore::RecordingSessionStore()],
        observers=[@posoco.RecordingObserver::RecordingObserver()],
      ),
    ],
    config=@posoco.tk_config(),
  )
  ignore(agent.run_turn(@posoco.tk_user_msg("beta flags please"), "session_1"))
  inspect(model.received_messages.length(), content="2")
  // One working-memory read for the whole session, not one per model call.
  inspect(wm_read_call_count(mcp), content="1")
  guard injected_memory_text(model.received_messages[0]) is Some(first) else {
    fail("expected the memory message in the first payload")
  }
  guard injected_memory_text(model.received_messages[1]) is Some(second) else {
    fail("expected the memory message to persist into the second payload")
  }
  inspect(first == second, content="true")
}

///|
/// e2e: with a memory provider composed, core registers its built-in
/// memory_search / memory_add exactly once each — no collision with this
/// extension's own tool surface, which rides alongside.
async test "e2e: composition carries core's builtin memory tools without collision" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_working_memory", mcp_ok("{\"exists\":false}")),
    ]),
  )
  let ext = nmem_ext(mcp~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  // Composition itself succeeding is the ToolCollision fail-fast passing.
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(
        id="nowledge_mem",
        tools=[ext as &@posoco.ToolProvider],
        memory=[ext as &@posoco.MemoryPort],
        lifecycle=[ext as &@posoco.Lifecycle],
      ),
      @posoco.tk_ext(
        id="io",
        sessions=[@posoco.RecordingSessionStore::RecordingSessionStore()],
        observers=[@posoco.RecordingObserver::RecordingObserver()],
      ),
    ],
    config=@posoco.tk_config(),
  )
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  let names : Array[String] = []
  for def in model.received_tools[0] {
    names.push(def.name.to_string())
  }
  for builtin in ["memory_search", "memory_add"] {
    let mut seen = 0
    for name in names {
      if name == builtin {
        seen = seen + 1
      }
    }
    inspect(seen, content="1")
  }
  // This extension's own surface rides alongside, minus the retired names.
  assert_true(names.contains("nmem_status"))
  assert_true(names.contains("read_context_bundle"))
  assert_false(names.contains("read_working_memory"))
}

///|
/// e2e B: the write queue loop — add and delete queue their ops, and the
/// drain replays every op against the MCP tools.
async test "e2e B: add-delete round trip drains both ops to the server" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("memory_add", mcp_ok("{\"id\":\"mem_42\"}")),
      ("memory_delete", mcp_ok("{}")),
    ]),
  )
  let ext = nmem_ext(mcp~)
  ignore(
    @posoco.MemoryPort::store(
      ext,
      content="deploy fridays only",
      metadata=Map::from_array([]),
    ),
  )
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  @posoco.MemoryPort::delete(ext, "mem_42")
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  inspect(mcp.calls.length(), content="2")
  inspect(mcp.calls[0].0, content="memory_add")
  inspect(
    json_field(recorded_args(mcp, 0), "content")
    is Some(Json::String("deploy fridays only")),
    content="true",
  )
  inspect(mcp.calls[1].0, content="memory_delete")
  inspect(
    json_field(recorded_args(mcp, 1), "memory_id")
    is Some(Json::String("mem_42")),
    content="true",
  )
}

///|
/// e2e: a resumed process on the SAME session keeps the persisted memory
/// message byte-identical and reads nothing — the session's history was
/// derived under that injection, so it is never swapped for a newer one.
async test "e2e: a resumed process keeps the persisted injection and reads nothing" {
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let mcp1 = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      (
        "read_working_memory",
        mcp_ok(
          "{\"exists\":true,\"content\":\"alpha fact from the first process\"}",
        ),
      ),
    ]),
  )
  let ext1 = nmem_ext(mcp=mcp1)
  let model1 = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let agent1 = mem_agent_store(ext1, model1, store)
  ignore(agent1.run_turn(@posoco.tk_user_msg("first question"), "session_1"))
  guard injected_memory_text(model1.received_messages[0]) is Some(first) else {
    fail("expected the first process to inject memory")
  }
  assert_true(first.contains("alpha fact"))
  let first_count = model1.received_messages[0].length()
  // A fresh process on the same session: even though the server's working
  // memory changed, the persisted injection wins.
  let mcp2 = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      (
        "read_working_memory",
        mcp_ok(
          "{\"exists\":true,\"content\":\"beta fact from the resumed process\"}",
        ),
      ),
    ]),
  )
  let ext2 = nmem_ext(mcp=mcp2)
  let model2 = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let agent2 = mem_agent_store(ext2, model2, store)
  ignore(agent2.run_turn(@posoco.tk_user_msg("second question"), "session_1"))
  let messages = model2.received_messages[0]
  guard injected_memory_text(messages) is Some(second) else {
    fail("expected the persisted injection to survive the resume")
  }
  inspect(first == second, content="true")
  assert_false(second.contains("beta fact"))
  // Still exactly one injected memory message, still directly after the
  // system prompt, and the resumed process read the server zero times.
  inspect(injected_memory_count(messages), content="1")
  inspect(injected_memory_text([messages[1]]) is Some(_), content="true")
  inspect(wm_read_call_count(mcp2), content="0")
  // One prior user message and its assistant reply precede the new user
  // message: the count grew by exactly those, never by an extra injection.
  inspect(messages.length() - first_count, content="2")
}

///|
/// e2e C: the constructor's source_app is the one identity that reaches every
/// surface — synced thread ids, prompt guidance, and truncation markers.
async test "e2e C: source_app propagates to thread ids, guidance, and markers" {
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem(
    source_app="cetas",
    transport~,
    mcp=FakeNmemMcp::FakeNmemMcp(
      script=Map::from_array([
        ("read_working_memory", mcp_ok("{\"exists\":false}")),
      ]),
    ),
    platform=FakePlatform::FakePlatform(),
  )
  let prompt = ext.system_prompt()
  assert_true(prompt.contains("Cetas"))
  assert_true(prompt.contains("\"cetas\""))
  assert_false(prompt.contains("Posoco"))
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
  ])
  let agent = nmem_agent(ext, model)
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "session_1"))
  ext.flush_pending()
  inspect(transport.requests.length(), content="1")
  inspect(body_thread_id(transport.requests[0].1), content="cetas-session_1")
  inspect(
    json_field(transport.requests[0].1, "source") is Some(Json::String("cetas")),
    content="true",
  )
  let long = repeat_text("x", 25000)
  assert_true(
    truncate_message(long, "cetas").contains(
      "[Cetas message truncated by Nowledge Mem plugin]",
    ),
  )
  inspect(
    context_truncation_note("cetas"),
    content="[Nowledge Mem context truncated by Cetas plugin]",
  )
  inspect(thread_title([], "cetas"), content="Cetas session")
}
