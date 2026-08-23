///|
/// Text of the first `[MEMORY]` SystemMessage in a model payload; `None` when
/// the retrieval hook injected nothing.
fn memory_message_text(messages : Array[@posoco.Message]) -> String? {
  for message in messages {
    match message {
      @posoco.Message::SystemMessage(content~) =>
        match content {
          [@posoco.Content::Text(text), ..] =>
            if text.has_prefix("[MEMORY]") {
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
/// Agent wiring for the e2e cases: declaring the extension's memory port is
/// what attaches core's MemoryRetrievalHook.
fn mem_agent(
  ext : NowledgeMem,
  model : @posoco.ScriptedModel,
) -> @posoco.Agent raise {
  @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(
        id="nowledge_mem",
        memory=[ext as &@posoco.MemoryPort],
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
/// e2e A: core's MemoryRetrievalHook (top_k 5) carries both staged entries to
/// the model, ordered by the local score — the high-overlap high-importance
/// entry ahead of the low-overlap importance-less one.
async test "e2e A: [MEMORY] injection carries both entries in score order" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        { exit: 0, stdout: "{\"rendered_markdown\":\"ctx\"}", stderr: "" },
      ),
      ("m:-n", { exit: 0, stdout: "{\"memories\":[]}", stderr: "" }),
    ]),
  )
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  ignore(
    @posoco.MemoryPort::store(
      ext,
      mem_entry(
        id="",
        content="postgres database migrations workflow",
        importance=0.9,
      ),
    ),
  )
  // Low overlap and no importance metadata key at all (scores 0.5).
  ignore(
    @posoco.MemoryPort::store(ext, {
      id: "",
      content: "a database of pasta recipes",
      metadata: Map::from_array([]),
      score: None,
    }),
  )
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let agent = mem_agent(ext, model)
  ignore(
    agent.run_turn(@posoco.tk_user_msg("database migrations"), "session_1"),
  )
  inspect(model.received_messages.length() > 0, content="true")
  guard memory_message_text(model.received_messages[0]) is Some(memory) else {
    fail("expected a [MEMORY] system message")
  }
  match
    (
      memory.find("postgres database migrations workflow"),
      memory.find("a database of pasta recipes"),
    ) {
    (Some(high_at), Some(low_at)) => assert_true(high_at < low_at)
    _ => fail("expected both staged entries in the [MEMORY] message")
  }
}

///|
/// e2e B: the full port loop — store, search (port direct), delete, and the
/// drain replaying every op against the CLI (`m add` then `m delete -f`).
async test "e2e B: store-search-delete round trip drains both ops to the CLI" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:add", { exit: 0, stdout: "{\"id\":\"mem_42\"}", stderr: "" }),
      ("m:delete", { exit: 0, stdout: "{}", stderr: "" }),
    ]),
  )
  let ext = NowledgeMem::new(
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
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="deploy fridays")).length(),
    content="1",
  )
  ext.drain_memory_ops()
  inspect(ext.mem.index.length(), content="1")
  inspect(ext.mem.index[0].id, content="mem_42")
  @posoco.MemoryPort::delete(ext, "mem_42")
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="deploy fridays")).length(),
    content="0",
  )
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
/// e2e C: the constructor's source_app is the one identity that reaches every
/// surface — synced thread ids, prompt guidance, and truncation markers.
async test "e2e C: source_app propagates to thread ids, guidance, and markers" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        { exit: 0, stdout: "{\"rendered_markdown\":\"ctx\"}", stderr: "" },
      ),
    ]),
  )
  let transport = EchoNmemTransport::EchoNmemTransport()
  let ext = NowledgeMem::new(source_app="cetas", transport~, runner~)
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
    content="[Nowledge Mem startup context truncated by Cetas plugin]",
  )
  inspect(thread_title([], "cetas"), content="Cetas session")
}
