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
  { id, content, metadata, score: None, }
}

///|
/// A MemoryQuery; the passive read ignores every field, so tests vary only
/// the query text to pin exactly that.
fn mem_query(query~ : String) -> @posoco.MemoryQuery {
  { query, top_k: 5, threshold: None, filter: Map::from_array([]), }
}

///|
/// Extension over the test fakes with scripted MCP replies.
fn mem_ext(
  script? : Map[String, FakeMcpEntry] = Map::from_array([]),
) -> NowledgeMem {
  nmem_ext(mcp=FakeNmemMcp::FakeNmemMcp(script~))
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
/// reads the working memory (read_working_memory with the ambient scope),
/// mapping the payload content onto one working-memory entry.
async test "MemoryPort: first search reads working memory, ignoring the query" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      (
        "read_working_memory",
        mcp_ok(
          "{\"exists\":true,\"content\":\"deploy via the staging pipeline\"}",
        ),
      ),
    ]),
  )
  let ext = nmem_ext(mcp~)
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
  // The read carried the ambient scope and host identity.
  inspect(mcp.calls.length(), content="1")
  let args = recorded_args(mcp, 0)
  inspect(
    json_field(args, "space_id") is Some(Json::String("team")),
    content="true",
  )
  inspect(
    json_field(args, "source_app") is Some(Json::String("posoco")),
    content="true",
  )
  inspect(ext.passive_read_done, content="true")
}

///|
async test "MemoryPort: an empty query still reads — the gate is not query-gated" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      (
        "read_working_memory",
        mcp_ok("{\"exists\":true,\"content\":\"briefing\"}"),
      ),
    ]),
  )
  let ext = nmem_ext(mcp~)
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="")).length(),
    content="1",
  )
  inspect(mcp.calls.length(), content="1")
  inspect(ext.passive_read_done, content="true")
}

///|
async test "MemoryPort: plain-text working memory degrades to the raw content" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_working_memory", mcp_ok("# Working Memory\n- ship it")),
    ]),
  )
  let ext = nmem_ext(mcp~)
  let hits = @posoco.MemoryPort::search(ext, mem_query(query="x"))
  inspect(hits.length(), content="1")
  inspect(hits[0].content, content="# Working Memory\n- ship it")
  inspect(hits[0].id, content="wm")
}

///|
async test "MemoryPort: exists false is a clean miss, not a failure" {
  let ext = mem_ext(
    script=Map::from_array([
      ("read_working_memory", mcp_ok("{\"exists\":false}")),
    ]),
  )
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="anything")).length(),
    content="0",
  )
  inspect(ext.mem.last_error is None, content="true")
  inspect(ext.passive_read_done, content="true")
}

///|
async test "MemoryPort: second search returns empty with no mcp call" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_working_memory", mcp_ok("{\"exists\":false}")),
    ]),
  )
  let ext = nmem_ext(mcp~)
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="first")).length(),
    content="0",
  )
  inspect(mcp.calls.length(), content="1")
  let again = @posoco.MemoryPort::search(ext, mem_query(query="second"))
  inspect(again.length(), content="0")
  inspect(mcp.calls.length(), content="1")
}

///|
async test "MemoryPort: failed read raises, spends the gate, records last_error" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_working_memory", FakeMcpEntry::Fail("connect refused")),
    ]),
  )
  let ext = nmem_ext(mcp~)
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
  assert_true(err.contains("working memory read failed"))
  assert_true(err.contains("connect refused"))
  // The spent gate swallows the next attempt without another call.
  inspect(
    @posoco.MemoryPort::search(ext, mem_query(query="y")).length(),
    content="0",
  )
  inspect(mcp.calls.length(), content="1")
}

///|
async test "MemoryPort: a server-flagged error raises Search and spends the gate" {
  let ext = mem_ext(
    script=Map::from_array([
      ("read_working_memory", mcp_server_error("working memory exploded")),
    ]),
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
  assert_true(err.contains("working memory exploded"))
}

///|
async test "drain: acknowledged add clears the queue with the metadata args" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([("memory_add", mcp_ok("{\"id\":\"mem_123\"}"))]),
  )
  let ext = nmem_ext(mcp~)
  ext.config = Some(lane_config())
  ignore(
    @posoco.MemoryPort::store(
      ext,
      mem_entry(id="", content="durable decision", title="D1"),
    ),
  )
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  inspect(mcp.calls.length(), content="1")
  inspect(mcp.calls[0].0, content="memory_add")
  let args = recorded_args(mcp, 0)
  inspect(
    json_field(args, "content") is Some(Json::String("durable decision")),
    content="true",
  )
  inspect(json_field(args, "title") is Some(Json::String("D1")), content="true")
  inspect(
    json_field(args, "importance") is Some(Json::Number(0.5, ..)),
    content="true",
  )
  inspect(
    json_field(args, "source_app") is Some(Json::String("posoco")),
    content="true",
  )
}

///|
async test "drain: an add reply without an id still counts as success" {
  // With MCP the server's own error flag is the failure signal; a clean
  // reply that happens to carry no id is an acknowledged write.
  let ext = mem_ext(script=Map::from_array([("memory_add", mcp_ok("{}"))]))
  ignore(@posoco.MemoryPort::store(ext, mem_entry(id="", content="note")))
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  inspect(ext.mem.last_error is None, content="true")
}

///|
async test "drain: failed adds re-enqueue at the tail and record last_error" {
  let ext = mem_ext(
    script=Map::from_array([("memory_add", FakeMcpEntry::Fail("server down"))]),
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
async test "drain: a server-flagged add failure re-enqueues and records detail" {
  let ext = mem_ext(
    script=Map::from_array([("memory_add", mcp_server_error("quota exceeded"))]),
  )
  ignore(@posoco.MemoryPort::store(ext, mem_entry(id="", content="note")))
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="1")
  guard ext.mem.last_error is Some(err) else {
    fail("expected last_error to be recorded")
  }
  assert_true(err.contains("quota exceeded"))
}

///|
async test "drain: delete issues memory_delete with the memory_id argument" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([("memory_delete", mcp_ok("{}"))]),
  )
  let ext = nmem_ext(mcp~)
  @posoco.MemoryPort::delete(ext, "mem_7")
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  inspect(mcp.calls.length(), content="1")
  inspect(mcp.calls[0].0, content="memory_delete")
  let args = recorded_args(mcp, 0)
  inspect(
    json_field(args, "memory_id") is Some(Json::String("mem_7")),
    content="true",
  )
}

///|
async test "drain: a server-flagged delete failure re-enqueues" {
  let ext = mem_ext(
    script=Map::from_array([("memory_delete", mcp_server_error("not found"))]),
  )
  @posoco.MemoryPort::delete(ext, "mem_7")
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="1")
  guard ext.mem.last_error is Some(err) else {
    fail("expected last_error to be recorded")
  }
  assert_true(err.contains("not found"))
}
