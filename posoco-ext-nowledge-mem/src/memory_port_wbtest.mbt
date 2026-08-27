///|
/// One memory entry for queue fixtures; `id` is "" for store calls
/// (store brands the pending ticket itself).
fn mem_entry(
  id~ : String,
  content~ : String,
  title? : String = "",
  importance? : Double = 0.5,
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
/// A MemoryQuery; the passive read ignores every field, so tests vary only
/// the query text to pin exactly that.
fn mem_query(query~ : String) -> @posoco.MemoryQuery {
  { query, top_k: 5, threshold: None, filter: Map::from_array([]) }
}

///|
/// Extension over echo transport with scripted CLI replies.
fn mem_ext(
  replies? : Map[String, CliOutcome] = Map::from_array([]),
) -> NowledgeMem {
  NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner=FakeRunner::FakeRunner(replies~),
  )
}

///|
async test "MemoryPort: store queues an Add and hands out sequential pending tickets" {
  let ext = mem_ext()
  let pending_id = @posoco.MemoryPort::store(
    ext,
    mem_entry(id="", content="Postgres migrations live in db/migrations"),
  )
  inspect(pending_id, content="pending:1")
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
async test "MemoryPort: delete drops pending Adds whole, remote ids queue Delete" {
  let ext = mem_ext()
  let pending_id = @posoco.MemoryPort::store(
    ext,
    mem_entry(id="", content="temporary note"),
  )
  @posoco.MemoryPort::delete(ext, pending_id)
  inspect(ext.mem.queue.length(), content="0")
  @posoco.MemoryPort::delete(ext, "mem_9")
  inspect(ext.mem.queue.length(), content="1")
  match ext.mem.queue[0] {
    Delete(id~) => inspect(id, content="mem_9")
    Add(..) => fail("expected a queued Delete")
  }
}

///|
async test "MemoryPort: empty id raises MemoryError::Delete" {
  let ext = mem_ext()
  try @posoco.MemoryPort::delete(ext, "") catch {
    @posoco.MemoryError::Delete(message) => inspect(message, content="empty id")
    _ => fail("expected MemoryError::Delete")
  } noraise {
    _ => fail("expected delete to raise")
  }
}

///|
/// The one-shot gate: the first search ignores the query text entirely and
/// reads the working memory (`wm read` with the ambient --space), mapping
/// the payload content onto one working-memory entry.
async test "MemoryPort: first search reads working memory, ignoring the query" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "wm",
        {
          exit: 0,
          stdout: "{\"exists\":true,\"content\":\"deploy via the staging pipeline\"}",
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
  ext.config = Some(lane_config(space=Some("team")))
  let hits = @posoco.MemoryPort::search(ext, mem_query(query="deploy fridays"))
  inspect(hits.length(), content="1")
  inspect(hits[0].id, content="wm")
  inspect(hits[0].content, content="deploy via the staging pipeline")
  inspect(hits[0].score is None, content="true")
  inspect(
    hits[0].metadata.get("kind") is Some(Json::String("working_memory")),
    content="true",
  )
  debug_inspect(
    runner.calls[0],
    content=(
      #|["--json", "wm", "read", "--space", "team"]
    ),
  )
  inspect(ext.passive_read_done, content="true")
}

///|
async test "MemoryPort: an empty query still reads — the gate is not query-gated" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "wm",
        {
          exit: 0,
          stdout: "{\"exists\":true,\"content\":\"briefing\"}",
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
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="")).length(),
    content="1",
  )
  inspect(runner.calls.length(), content="1")
  inspect(ext.passive_read_done, content="true")
}

///|
async test "MemoryPort: exists false is a clean miss, not a failure" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="anything")).length(),
    content="0",
  )
  inspect(ext.mem.last_error is None, content="true")
  inspect(ext.passive_read_done, content="true")
}

///|
async test "MemoryPort: second search returns empty with no runner call" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="first")).length(),
    content="0",
  )
  inspect(runner.calls.length(), content="1")
  let again = @posoco.MemoryPort::search(ext, mem_query(query="second"))
  inspect(again.length(), content="0")
  inspect(runner.calls.length(), content="1")
}

///|
async test "MemoryPort: failed read raises, spends the gate, records last_error" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 1, stdout: "", stderr: "server down" }),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  try @posoco.MemoryPort::search(ext, mem_query(query="x")) catch {
    @posoco.MemoryError::Search(_) => ()
    _ => fail("expected MemoryError::Search")
  } noraise {
    _ => fail("expected search to raise")
  }
  inspect(ext.passive_read_done, content="true")
  guard ext.mem.last_error is Some(err) else {
    fail("expected last_error to be recorded")
  }
  assert_true(err.contains("working memory read failed (1)"))
  assert_true(err.contains("server down"))
  // The spent gate swallows the next attempt without a CLI call.
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="y")).length(),
    content="0",
  )
  inspect(runner.calls.length(), content="1")
}

///|
async test "MemoryPort: unparseable payload raises Search and spends the gate" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "not json", stderr: "" }),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  try @posoco.MemoryPort::search(ext, mem_query(query="x")) catch {
    @posoco.MemoryError::Search(reason) =>
      inspect(reason, content="unparseable working-memory payload")
    _ => fail("expected MemoryError::Search")
  } noraise {
    _ => fail("expected search to raise")
  }
  inspect(ext.passive_read_done, content="true")
}

///|
async test "drain: acknowledged add clears the queue with the metadata argv" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:add", { exit: 0, stdout: "{\"id\":\"mem_123\"}", stderr: "" }),
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
      mem_entry(id="", content="durable decision", title="D1"),
    ),
  )
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
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
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  ignore(@posoco.MemoryPort::store(ext, mem_entry(id="", content="note")))
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
}

///|
async test "drain: failed adds re-enqueue at the tail and record last_error" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:add", { exit: 1, stdout: "", stderr: "server down" }),
    ]),
  )
  let ext = NowledgeMem(
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
  guard ext.mem.last_error is Some(_) else {
    fail("expected last_error to be recorded")
  }
}

///|
async test "drain: an add response without an id counts as failure" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([("m:add", { exit: 0, stdout: "{}", stderr: "" })]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
  ignore(@posoco.MemoryPort::store(ext, mem_entry(id="", content="note")))
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="1")
  guard ext.mem.last_error is Some(err) else {
    fail("expected last_error to be recorded")
  }
  inspect(err, content="memory add response carried no id")
}

///|
async test "drain: delete issues m delete with -f and clears the op" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:delete", { exit: 0, stdout: "{}", stderr: "" }),
    ]),
  )
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
  )
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
