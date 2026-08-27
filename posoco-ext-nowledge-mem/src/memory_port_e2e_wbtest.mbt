///|
/// Opening of core's injected memory section — the header the retrieval
/// hook injects and replaces in place.
let memory_section_prefix : String = "## Any Memory About This Work"

///|
/// Text of the first memory-section SystemMessage in a model payload;
/// `None` when the retrieval hook injected nothing.
fn memory_message_text(messages : Array[@posoco.Message]) -> String? {
  for message in messages {
    match message {
      @posoco.Message::SystemMessage(content~) =>
        match content {
          [@posoco.Content::Text(text), ..] =>
            if text.has_prefix(memory_section_prefix) {
              return Some(text)
            }
          _ => ()
        }
      _ => ()
    }
  }
  None
}

///|
/// How many memory-section SystemMessages a payload carries (replace-in-
/// place keeps this at 1).
fn memory_section_count(messages : Array[@posoco.Message]) -> Int {
  let mut count = 0
  for message in messages {
    match message {
      @posoco.Message::SystemMessage(content~) =>
        match content {
          [@posoco.Content::Text(text), ..] =>
            if text.has_prefix(memory_section_prefix) {
              count = count + 1
            }
          _ => ()
        }
      _ => ()
    }
  }
  count
}

///|
/// How many `wm read` CLI calls the runner saw.
fn wm_read_call_count(runner : FakeRunner) -> Int {
  let mut count = 0
  for call in runner.calls {
    if call.contains("wm") {
      count = count + 1
    }
  }
  count
}

///|
/// Agent wiring for the e2e cases: declaring the extension's memory port is
/// what attaches core's MemoryRetrievalHook.
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
        memory=[ext as &@posoco.MemoryPort],
        observers=[ext as &@posoco.Observer],
        hooks=[ext as &@posoco.PipelineHook],
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
/// e2e A: the one-shot working-memory read lands as one memory-section
/// SystemMessage (header + provenance line), positioned right after the
/// system prompt.
async test "e2e A: first-turn working-memory read lands as a memory section after the system prompt" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "wm",
        {
          exit: 0,
          stdout: "{\"exists\":true,\"content\":\"Ship the zephyr widget via the staging pipeline\"}",
          stderr: "",
        },
      ),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
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
  guard memory_message_text(messages) is Some(memory) else {
    fail("expected a memory section system message")
  }
  assert_true(memory.contains("from Nowledge Mem. For Your Information."))
  assert_true(
    memory.contains("- Ship the zephyr widget via the staging pipeline"),
  )
  // Position: the memory section sits directly after the assembled system prompt.
  inspect(memory_section_count(messages), content="1")
  inspect(memory_message_text([messages[1]]) is Some(_), content="true")
  inspect(wm_read_call_count(runner), content="1")
}

///|
/// e2e: a tool round-trip means two model calls in one turn — the spent
/// gate keeps the second call off the CLI, and the injected memory section
/// persists verbatim in both payloads.
async test "e2e: same-turn second model call does not re-run the CLI and keeps the memory section" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "wm",
        {
          exit: 0,
          stdout: "{\"exists\":true,\"content\":\"answer with beta flags\"}",
          stderr: "",
        },
      ),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
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
        memory=[ext as &@posoco.MemoryPort],
        observers=[ext as &@posoco.Observer],
        hooks=[ext as &@posoco.PipelineHook],
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
  // One working-memory read for the whole turn, not one per model call.
  inspect(wm_read_call_count(runner), content="1")
  guard memory_message_text(model.received_messages[0]) is Some(first) else {
    fail("expected the memory section in the first payload")
  }
  guard memory_message_text(model.received_messages[1]) is Some(second) else {
    fail("expected the memory section to persist into the second payload")
  }
  inspect(first == second, content="true")
}

///|
/// e2e B: the port loop that remains — store and delete queue their ops,
/// and the drain replays every op against the CLI (`m add` then
/// `m delete -f`).
async test "e2e B: store-delete round trip drains both ops to the CLI" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:add", { exit: 0, stdout: "{\"id\":\"mem_42\"}", stderr: "" }),
      ("m:delete", { exit: 0, stdout: "{}", stderr: "" }),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  ignore(
    @posoco.MemoryPort::store(
      ext,
      mem_entry(id="", content="deploy fridays only"),
    ),
  )
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  @posoco.MemoryPort::delete(ext, "mem_42")
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  inspect(runner.calls.length(), content="2")
  debug_inspect(
    runner.calls[0],
    content=(
      #|["--json", "m", "add", "deploy fridays only", "-i", "0.5"]
    ),
  )
  debug_inspect(
    runner.calls[1],
    content=(
      #|["--json", "m", "delete", "mem_42", "-f"]
    ),
  )
}

///|
/// e2e: resume gets a fresh gate — a second extension instance on the SAME
/// session store re-reads the working memory at its first turn, and core's
/// hook replaces the persisted memory section in place (one section
/// message, new content) instead of appending a second one.
async test "e2e: a resumed process re-reads working memory and replaces the memory section in place" {
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let runner1 = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "wm",
        {
          exit: 0,
          stdout: "{\"exists\":true,\"content\":\"alpha fact from the first process\"}",
          stderr: "",
        },
      ),
    ]),
  )
  let ext1 = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner=runner1,
  )
  let model1 = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let agent1 = mem_agent_store(ext1, model1, store)
  ignore(agent1.run_turn(@posoco.tk_user_msg("first question"), "session_1"))
  guard memory_message_text(model1.received_messages[0]) is Some(first) else {
    fail("expected the first process to inject a memory section")
  }
  assert_true(first.contains("alpha fact"))
  let first_count = model1.received_messages[0].length()
  // A fresh process on the same session: new gate, new scripted hit.
  let runner2 = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "wm",
        {
          exit: 0,
          stdout: "{\"exists\":true,\"content\":\"beta fact from the resumed process\"}",
          stderr: "",
        },
      ),
    ]),
  )
  let ext2 = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner=runner2,
  )
  inspect(ext2.passive_read_done, content="false")
  let model2 = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let agent2 = mem_agent_store(ext2, model2, store)
  ignore(agent2.run_turn(@posoco.tk_user_msg("second question"), "session_1"))
  let messages = model2.received_messages[0]
  guard memory_message_text(messages) is Some(second) else {
    fail("expected the resumed process to inject a memory section")
  }
  assert_true(second.contains("beta fact"))
  assert_false(second.contains("alpha fact"))
  // Replaced in place, not appended: still exactly one memory-section message,
  // still directly after the system prompt.
  inspect(memory_section_count(messages), content="1")
  inspect(memory_message_text([messages[1]]) is Some(_), content="true")
  // One prior user message and its assistant reply precede the new user
  // message: the count grew by exactly those, never by an extra memory section.
  inspect(messages.length() - first_count, content="2")
}

///|
/// e2e C: the constructor's source_app is the one identity that reaches every
/// surface — synced thread ids, prompt guidance, and truncation markers.
async test "e2e C: source_app propagates to thread ids, guidance, and markers" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
    ]),
  )
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem(source_app="cetas", transport~, runner~)
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
