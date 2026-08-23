///|
/// One memory entry for index/queue fixtures; `id` is "" for store calls
/// (store brands the pending ticket itself).
fn mem_entry(
  id~ : String,
  content~ : String,
  title? : String = "",
  importance? : Double = NMEM_DEFAULT_IMPORTANCE,
  labels? : Array[String] = [],
) -> @posoco.MemoryEntry {
  let metadata : Map[String, Json] = Map::from_array([])
  if title != "" {
    metadata["title"] = Json::string(title)
  }
  metadata["importance"] = Json::number(importance)
  if !labels.is_empty() {
    metadata["labels"] = Json::array(labels.map(label => Json::string(label)))
  }
  { id, content, metadata, score: None }
}

///|
/// A MemoryQuery; `labels` non-empty installs the "labels" filter key.
fn mem_query(
  query~ : String,
  top_k? : Int = 5,
  threshold? : Double? = None,
  labels? : Array[String] = [],
) -> @posoco.MemoryQuery {
  let filter : Map[String, Json] = if labels.is_empty() {
    Map::from_array([])
  } else {
    Map::from_array([
      ("labels", Json::array(labels.map(label => Json::string(label)))),
    ])
  }
  { query, top_k, threshold, filter }
}

///|
/// Extension over echo transport with scripted CLI replies.
fn mem_ext(
  replies? : Map[String, CliOutcome] = Map::from_array([]),
) -> NowledgeMem {
  NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner=FakeRunner::FakeRunner(replies~),
  )
}

///|
test "MemoryPort: store stages a pending entry that search finds immediately" {
  let ext = mem_ext()
  let pending_id = @posoco.MemoryPort::store(
    ext,
    mem_entry(id="", content="Postgres migrations live in db/migrations"),
  )
  inspect(pending_id, content="pending:1")
  let hits = @posoco.MemoryPort::search(
    ext,
    mem_query(query="postgres migrations"),
  )
  inspect(hits.length(), content="1")
  inspect(hits[0].id, content="pending:1")
  inspect(hits[0].score is Some(_), content="true")
  inspect(ext.mem.queue.length(), content="1")
  match ext.mem.queue[0] {
    Add(pending_id~, ..) => inspect(pending_id, content="pending:1")
    Delete(..) => fail("expected a queued Add")
  }
  // Second store gets the next ticket.
  let second = @posoco.MemoryPort::store(
    ext,
    mem_entry(id="", content="another fact"),
  )
  inspect(second, content="pending:2")
}

///|
test "MemoryPort: search ranks by overlap and importance, applies threshold, labels, top_k" {
  let ext = mem_ext()
  ext.mem.index.push(
    mem_entry(
      id="mem_a",
      content="postgres database migrations workflow",
      importance=0.9,
      labels=["backend"],
    ),
  )
  ext.mem.index.push(
    mem_entry(
      id="mem_b",
      content="database naming conventions",
      importance=0.2,
      labels=["misc"],
    ),
  )
  ext.mem.index.push(
    mem_entry(id="mem_c", content="cooking pasta recipes", importance=0.95),
  )
  // mem_a: 2 token hits * 2.0 + 0.9 + whole-string 1.0; mem_b: 1 hit + 0.2;
  // mem_c: no match.
  let hits = @posoco.MemoryPort::search(
    ext,
    mem_query(query="database migrations"),
  )
  inspect(hits.length(), content="2")
  inspect(hits[0].id, content="mem_a")
  inspect(hits[1].id, content="mem_b")
  guard hits[0].score is Some(top) else { fail("expected a score") }
  guard hits[1].score is Some(second) else { fail("expected a score") }
  assert_true(top > 5.0)
  assert_true(second < 3.0)
  let strict = @posoco.MemoryPort::search(
    ext,
    mem_query(query="database migrations", threshold=Some(3.0)),
  )
  inspect(strict.length(), content="1")
  inspect(strict[0].id, content="mem_a")
  let labeled = @posoco.MemoryPort::search(
    ext,
    mem_query(query="database", labels=["misc"]),
  )
  inspect(labeled.length(), content="1")
  inspect(labeled[0].id, content="mem_b")
  let top1 = @posoco.MemoryPort::search(
    ext,
    mem_query(query="database migrations", top_k=1),
  )
  inspect(top1.length(), content="1")
}

///|
test "MemoryPort: title tokens count and missing importance defaults to 0.5" {
  let ext = mem_ext()
  ext.mem.index.push(
    mem_entry(id="mem_t", content="unrelated body", title="kubernetes ingress"),
  )
  ext.mem.index.push({
    id: "mem_plain",
    content: "ingress controllers compared",
    metadata: Map::from_array([]),
    score: None,
  })
  // Two tokens so neither entry catches the whole-string bonus.
  let hits = @posoco.MemoryPort::search(ext, mem_query(query="ingress gateway"))
  inspect(hits.length(), content="2")
  guard hits[1].score is Some(plain) else { fail("expected a score") }
  // 1 token hit * 2.0 + default importance 0.5.
  inspect(plain == 2.5, content="true")
}

///|
test "MemoryPort: delete drops pending entries whole, remote ids queue Delete" {
  let ext = mem_ext()
  let pending_id = @posoco.MemoryPort::store(
    ext,
    mem_entry(id="", content="temporary note"),
  )
  @posoco.MemoryPort::delete(ext, pending_id)
  inspect(ext.mem.index.length(), content="0")
  inspect(ext.mem.queue.length(), content="0")
  ext.mem.index.push(mem_entry(id="mem_9", content="remote fact"))
  @posoco.MemoryPort::delete(ext, "mem_9")
  inspect(ext.mem.index.length(), content="0")
  inspect(ext.mem.queue.length(), content="1")
  match ext.mem.queue[0] {
    Delete(id~) => inspect(id, content="mem_9")
    Add(..) => fail("expected a queued Delete")
  }
}

///|
test "MemoryPort: empty id raises MemoryError::Delete" {
  let ext = mem_ext()
  try @posoco.MemoryPort::delete(ext, "") catch {
    @posoco.MemoryError::Delete(message) => inspect(message, content="empty id")
    _ => fail("expected MemoryError::Delete")
  } noraise {
    _ => fail("expected delete to raise")
  }
}

///|
async test "drain: acknowledged add swaps the pending ticket for the server id" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:add", { exit: 0, stdout: "{\"id\":\"mem_123\"}", stderr: "" }),
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
      mem_entry(id="", content="durable decision", title="D1"),
    ),
  )
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  inspect(ext.mem.index.length(), content="1")
  inspect(ext.mem.index[0].id, content="mem_123")
  inspect(ext.mem.index[0].content, content="durable decision")
  inspect(runner.calls.length(), content="1")
  debug_inspect(
    runner.calls[0],
    content=(
      #|["--json", "m", "add", "durable decision", "-t", "D1", "-i", "0.5"]
    ),
  )
}

///|
async test "drain: nested memory.id payload shape is accepted" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "m:add",
        { exit: 0, stdout: "{\"memory\":{\"id\":\"mem_77\"}}", stderr: "" },
      ),
    ]),
  )
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  ignore(@posoco.MemoryPort::store(ext, mem_entry(id="", content="note")))
  ext.drain_memory_ops()
  inspect(ext.mem.index[0].id, content="mem_77")
  inspect(ext.mem.queue.length(), content="0")
}

///|
async test "drain: failed adds re-enqueue at the tail and record last_error" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:add", { exit: 1, stdout: "", stderr: "server down" }),
    ]),
  )
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  ignore(@posoco.MemoryPort::store(ext, mem_entry(id="", content="first")))
  ignore(@posoco.MemoryPort::store(ext, mem_entry(id="", content="second")))
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="2")
  match ext.mem.queue[0] {
    Add(pending_id~, ..) => inspect(pending_id, content="pending:1")
    Delete(..) => fail("expected a re-enqueued Add")
  }
  inspect(ext.mem.index[0].id, content="pending:1")
  inspect(ext.mem.index[1].id, content="pending:2")
  guard ext.mem.last_error is Some(_) else {
    fail("expected last_error to be recorded")
  }
}

///|
async test "drain: delete issues m delete with -f and clears the op" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:delete", { exit: 0, stdout: "{}", stderr: "" }),
    ]),
  )
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  ext.mem.index.push(mem_entry(id="mem_7", content="doomed"))
  @posoco.MemoryPort::delete(ext, "mem_7")
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  debug_inspect(
    runner.calls[0],
    content=(
      #|["--json", "m", "delete", "mem_7", "-f"]
    ),
  )
}

///|
async test "refresh: server memories replace the index, pending entries stay in front" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "m:-n",
        {
          exit: 0,
          stdout: "{\"memories\":[{\"id\":\"mem_1\",\"content\":\"remote fact\",\"title\":\"R\",\"importance\":0.7,\"labels\":[\"x\"]}]}",
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
  ext.config = Some(lane_config(space=Some("team")))
  ext.mem.index.push(mem_entry(id="mem_old", content="stale"))
  ignore(
    @posoco.MemoryPort::store(ext, mem_entry(id="", content="still pending")),
  )
  ext.refresh_memory_index()
  inspect(ext.mem.index.length(), content="2")
  inspect(ext.mem.index[0].id, content="pending:1")
  inspect(ext.mem.index[1].id, content="mem_1")
  inspect(ext.mem.index[1].content, content="remote fact")
  inspect(
    ext.mem.index[1].metadata.get("title") is Some(Json::String("R")),
    content="true",
  )
  // The m-list refresh is space-scoped like every other m command.
  assert_true(runner.calls[0].contains("--space"))
  assert_true(runner.calls[0].contains("team"))
}

///|
async test "refresh: failure keeps the index and records last_error" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:-n", { exit: 1, stdout: "", stderr: "unavailable" }),
    ]),
  )
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  ext.config = Some(lane_config())
  ext.mem.index.push(mem_entry(id="mem_old", content="stale"))
  ext.refresh_memory_index()
  inspect(ext.mem.index.length(), content="1")
  inspect(ext.mem.index[0].id, content="mem_old")
  guard ext.mem.last_error is Some(_) else {
    fail("expected last_error to be recorded")
  }
}

///|
/// e2e: declaring the extension's manifest memory port is what wires core's
/// MemoryRetrievalHook — a memory stored before the turn must arrive at the
/// model as a `[MEMORY]` SystemMessage without any explicit call from the
/// host.
async test "e2e: stored memory is passively injected as a [MEMORY] system message" {
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
        content="Ship the zephyr widget via the staging pipeline",
      ),
    ),
  )
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(
        id="nowledge_mem",
        memory=[ext as &@posoco.MemoryPort],
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
  ignore(
    agent.run_turn(
      @posoco.tk_user_msg("how do I ship the zephyr widget"),
      "session_1",
    ),
  )
  inspect(model.received_messages.length() > 0, content="true")
  let mut found = false
  for message in model.received_messages[0] {
    match message {
      @posoco.Message::SystemMessage(content~) =>
        match content {
          [@posoco.Content::Text(text), ..] =>
            if text.has_prefix("[MEMORY]") && text.contains("zephyr widget") {
              found = true
            }
          _ => ()
        }
      _ => ()
    }
  }
  assert_true(found)
}
