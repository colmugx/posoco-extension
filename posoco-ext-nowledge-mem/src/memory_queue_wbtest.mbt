///|
/// Extension over the test fakes with scripted MCP replies.
fn mem_ext(
  script? : Map[String, FakeMcpEntry] = Map::from_array([]),
) -> NowledgeMem {
  nmem_ext(mcp=FakeNmemMcp::FakeNmemMcp(script~))
}

///|
async test "queue: add queues an Add and hands out sequential pending tickets" {
  let ext = mem_ext()
  let pending_id = @posoco.MemoryPort::store(
    ext,
    content="Postgres migrations live in db/migrations",
    metadata=Map::from_array([]),
  )
  inspect(pending_id, content="pending:1")
  inspect(ext.mem.queue.length(), content="1")
  match ext.mem.queue[0] {
    Add(pending_id~, ..) => inspect(pending_id, content="pending:1")
    Delete(..) => fail("expected a queued Add")
  }
  // Second add gets the next ticket.
  let second = @posoco.MemoryPort::store(
    ext,
    content="another fact",
    metadata=Map::from_array([]),
  )
  inspect(second, content="pending:2")
}

///|
async test "queue: delete drops pending Adds whole, remote ids queue Delete" {
  let ext = mem_ext()
  let pending_id = @posoco.MemoryPort::store(
    ext,
    content="temporary note",
    metadata=Map::from_array([]),
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
async test "queue: empty id raises MemoryError::Delete" {
  let ext = mem_ext()
  try @posoco.MemoryPort::delete(ext, "") catch {
    @posoco.MemoryError::Delete(message) => inspect(message, content="empty id")
    _ => fail("expected MemoryError::Delete")
  } noraise {
    _ => fail("expected delete to raise")
  }
}

///|
async test "drain: acknowledged add clears the queue with the metadata args" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([("memory_add", mcp_ok("{\"id\":\"mem_123\"}"))]),
  )
  let ext = nmem_ext(mcp~)
  ext.config = Some(lane_config())
  let metadata : Map[String, Json] = Map::from_array([
    ("title", Json::string("D1")),
    ("importance", Json::number(0.5)),
  ])
  ignore(@posoco.MemoryPort::store(ext, content="durable decision", metadata~))
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
async test "drain: the drain replays the stored content verbatim" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([("memory_add", mcp_ok("{\"id\":\"mem_1\"}"))]),
  )
  let ext = nmem_ext(mcp~)
  ext.config = Some(lane_config())
  let metadata : Map[String, Json] = Map::from_array([
    ("labels", Json::array([Json::string("deploy")])),
    ("unit_type", Json::string("procedure")),
  ])
  ignore(@posoco.MemoryPort::store(ext, content="ship via staging", metadata~))
  ext.drain_memory_ops()
  let args = recorded_args(mcp, 0)
  inspect(
    json_field(args, "labels") is Some(Json::Array([Json::String("deploy")])),
    content="true",
  )
  inspect(
    json_field(args, "unit_type") is Some(Json::String("procedure")),
    content="true",
  )
}

///|
async test "drain: an add reply without an id still counts as success" {
  // With MCP the server's own error flag is the failure signal; a clean
  // reply that happens to carry no id is an acknowledged write.
  let ext = mem_ext(script=Map::from_array([("memory_add", mcp_ok("{}"))]))
  ignore(
    @posoco.MemoryPort::store(ext, content="note", metadata=Map::from_array([])),
  )
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  inspect(ext.mem.last_error is None, content="true")
}

///|
async test "drain: failed adds re-enqueue at the tail and record last_error" {
  let ext = mem_ext(
    script=Map::from_array([("memory_add", FakeMcpEntry::Fail("server down"))]),
  )
  ignore(
    @posoco.MemoryPort::store(
      ext,
      content="first",
      metadata=Map::from_array([]),
    ),
  )
  ignore(
    @posoco.MemoryPort::store(
      ext,
      content="second",
      metadata=Map::from_array([]),
    ),
  )
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
  ignore(
    @posoco.MemoryPort::store(ext, content="note", metadata=Map::from_array([])),
  )
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
