///|
fn tool_call(name : String, arguments : Json) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked(name),
    arguments,
  }
}

///|
/// Extension over echo transport with a scripted MCP client, an optional
/// space-scoped config, and the delete-tool toggle.
fn tool_ext(
  mcp? : FakeNmemMcp = FakeNmemMcp::FakeNmemMcp(),
  expose_delete_tool? : Bool = false,
  space? : String? = None,
) -> NowledgeMem {
  let ext = NowledgeMem(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    mcp~,
    platform=FakePlatform::FakePlatform(),
    expose_delete_tool~,
  )
  ext.config = Some(lane_config(space~))
  ext
}

///|
/// Outcome text for Success/ToolReportedError assertions; "" for the rest.
fn outcome_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => content
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
    _ => ""
  }
}

///|
test "list_tools: five tools by default, memory_delete only when exposed" {
  let default = @posoco.ToolProvider::list_tools(tool_ext())
  inspect(default.length(), content="5")
  let names : Array[String] = []
  for def in default {
    names.push(def.name.to_string())
  }
  for
    expected in [
      "nmem_status", "read_context_bundle", "memory_update", "thread_search", "thread_fetch_messages",
    ] {
    assert_true(names.contains(expected))
  }
  // Retrieval and saving ride core's builtin memory tools — this extension
  // must neither shadow nor rename them.
  assert_false(names.contains("memory_search"))
  assert_false(names.contains("memory_add"))
  assert_false(names.contains("read_working_memory"))
  // thread_create went away with the CLI runner — no MCP counterpart.
  assert_false(names.contains("thread_create"))
  assert_false(names.contains("thread_show"))
  assert_false(names.contains("memory_delete"))
  let exposed = @posoco.ToolProvider::list_tools(
    tool_ext(expose_delete_tool=true),
  )
  inspect(exposed.length(), content="6")
  let exposed_names : Array[String] = []
  for def in exposed {
    exposed_names.push(def.name.to_string())
  }
  assert_true(exposed_names.contains("memory_delete"))
  // Placeholder owner and safe default policy are overwritten by the catalog.
  inspect(exposed[0].owner.to_string() == "placeholder", content="true")
  inspect(
    exposed[0].policy is @posoco.ExecutionPolicy::Parallel,
    content="true",
  )
}

///|
async test "nmem_status: probe report on success, failure message on error" {
  let ok_mcp = FakeNmemMcp::FakeNmemMcp(
    probe_result=Ok("nowledge-mem 0.10.72, 64 tools"),
  )
  let ok_ext = tool_ext(mcp=ok_mcp)
  let ok = @posoco.ToolProvider::execute(
    ok_ext,
    "nmem_status",
    tool_call("nmem_status", Json::object(Map::from_array([]))),
  )
  guard ok is @posoco.ToolOutcome::Success(content~, structured~) else {
    fail("expected success")
  }
  inspect(content, content="nowledge-mem 0.10.72, 64 tools")
  inspect(
    json_field(structured.unwrap(), "connected") is Some(Json::True),
    content="true",
  )
  let down_mcp = FakeNmemMcp::FakeNmemMcp(
    probe_result=Err("nowledge-mem mcp connect failed: refused"),
  )
  let down_ext = tool_ext(mcp=down_mcp)
  let down = @posoco.ToolProvider::execute(
    down_ext,
    "nmem_status",
    tool_call("nmem_status", Json::object(Map::from_array([]))),
  )
  guard down is @posoco.ToolOutcome::ToolReportedError(..) else {
    fail("expected a reported error")
  }
  assert_true(outcome_text(down).contains("refused"))
}

///|
async test "memory_update: tool args map id to memory_id with content and title" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([("memory_update", mcp_ok("{}"))]),
  )
  let ext = tool_ext(mcp~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_update",
    tool_call(
      "memory_update",
      j("{\"id\":\"mem_3\",\"content\":\"new text\",\"title\":\"New\"}"),
    ),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  inspect(mcp.calls[0].0, content="memory_update")
  let args = recorded_args(mcp, 0)
  inspect(
    json_field(args, "memory_id") is Some(Json::String("mem_3")),
    content="true",
  )
  inspect(
    json_field(args, "content") is Some(Json::String("new text")),
    content="true",
  )
  inspect(
    json_field(args, "title") is Some(Json::String("New")),
    content="true",
  )
}

///|
/// `memory_delete` goes through the `MemoryPort` `delete` slot: a real id
/// queues a remote delete (nothing reaches the server until the drain),
/// and the drain replays it as the server's `memory_id` argument.
async test "memory_delete: queues through the port and drains with memory_id" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([("memory_delete", mcp_ok("{}"))]),
  )
  let ext = tool_ext(mcp~, expose_delete_tool=true)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_delete",
    tool_call("memory_delete", j("{\"id\":\"mem_4\"}")),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  inspect(
    outcome_text(outcome),
    content="delete queued for mem_4; will sync to Nowledge Mem",
  )
  inspect(mcp.calls.length(), content="0")
  inspect(ext.mem.queue.length(), content="1")
  ext.drain_memory_ops()
  inspect(ext.mem.queue.length(), content="0")
  inspect(mcp.calls.length(), content="1")
  inspect(mcp.calls[0].0, content="memory_delete")
  let args = recorded_args(mcp, 0)
  inspect(
    json_field(args, "memory_id") is Some(Json::String("mem_4")),
    content="true",
  )
}

///|
async test "thread_fetch_messages: thread_id with optional paging args" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([("thread_fetch_messages", mcp_ok("{}"))]),
  )
  let ext = tool_ext(mcp~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "thread_fetch_messages",
    tool_call(
      "thread_fetch_messages",
      j("{\"thread_id\":\"th_1\",\"limit\":5,\"offset\":8}"),
    ),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  inspect(mcp.calls[0].0, content="thread_fetch_messages")
  let args = recorded_args(mcp, 0)
  inspect(
    json_field(args, "thread_id") is Some(Json::String("th_1")),
    content="true",
  )
  inspect(
    json_field(args, "limit") is Some(Json::Number(5.0, ..)),
    content="true",
  )
  inspect(
    json_field(args, "offset") is Some(Json::Number(8.0, ..)),
    content="true",
  )
}

///|
async test "thread_search: query and limit with identity scope" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([("thread_search", mcp_ok("{}"))]),
  )
  let ext = tool_ext(mcp~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "thread_search",
    tool_call("thread_search", j("{\"query\":\"deploy\",\"limit\":5}")),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  inspect(mcp.calls[0].0, content="thread_search")
  let args = recorded_args(mcp, 0)
  inspect(
    json_field(args, "query") is Some(Json::String("deploy")),
    content="true",
  )
  inspect(
    json_field(args, "limit") is Some(Json::Number(5.0, ..)),
    content="true",
  )
  inspect(
    json_field(args, "source_app") is Some(Json::String("posoco")),
    content="true",
  )
}

///|
async test "execute: unknown tool raises RuntimeError::UnknownTool" {
  let ext = tool_ext()
  try
    @posoco.ToolProvider::execute(
      ext,
      "thread_create",
      tool_call("thread_create", Json::object(Map::from_array([]))),
    )
  catch {
    @posoco.RuntimeError::UnknownTool(_) => ()
    _ => fail("expected UnknownTool")
  } noraise {
    _ => fail("expected execute to raise")
  }
}

///|
/// Retired names stay retired: the extension no longer dispatches the tools
/// core now owns (memory_search / memory_add) or the WM read the inbound
/// slot replaced.
async test "execute: retired tool names are unknown" {
  let ext = tool_ext()
  for name in ["memory_search", "memory_add", "read_working_memory"] {
    try
      @posoco.ToolProvider::execute(ext, name, tool_call(name, Json::null()))
    catch {
      @posoco.RuntimeError::UnknownTool(_) => ()
      _ => fail("expected UnknownTool for \{name}")
    } noraise {
      _ => fail("expected execute to raise for \{name}")
    }
  }
}

///|
async test "read_context_bundle: markdown chain, ambient scope" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      (
        "read_context_bundle",
        mcp_ok("{\"rendered_markdown\":\"# Bundle\",\"markdown\":\"shadowed\"}"),
      ),
    ]),
  )
  let ext = tool_ext(mcp~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "read_context_bundle",
    tool_call("read_context_bundle", Json::object(Map::from_array([]))),
  )
  guard outcome is @posoco.ToolOutcome::Success(content~, structured~) else {
    fail("expected success")
  }
  inspect(content, content="# Bundle")
  inspect(structured is Some(Json::Object(_)), content="true")
  inspect(mcp.calls[0].0, content="read_context_bundle")
  inspect(
    json_field(recorded_args(mcp, 0), "source_app")
    is Some(Json::String("posoco")),
    content="true",
  )
  // rendered_markdown absent: markdown, then content, carry the body.
  let md_mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      (
        "read_context_bundle",
        mcp_ok("{\"markdown\":\"md body\",\"content\":\"shadowed\"}"),
      ),
    ]),
  )
  let md_ext = tool_ext(mcp=md_mcp)
  let md = @posoco.ToolProvider::execute(
    md_ext,
    "read_context_bundle",
    tool_call("read_context_bundle", Json::object(Map::from_array([]))),
  )
  guard md is @posoco.ToolOutcome::Success(content=md_content, ..) else {
    fail("expected success")
  }
  inspect(md_content, content="md body")
  let plain_mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_context_bundle", mcp_ok("{\"content\":\"plain body\"}")),
    ]),
  )
  let plain_ext = tool_ext(mcp=plain_mcp)
  let plain = @posoco.ToolProvider::execute(
    plain_ext,
    "read_context_bundle",
    tool_call("read_context_bundle", Json::object(Map::from_array([]))),
  )
  guard plain is @posoco.ToolOutcome::Success(content=plain_content, ..) else {
    fail("expected success")
  }
  inspect(plain_content, content="plain body")
  // A configured space scopes the read.
  let scoped_mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_context_bundle", mcp_ok("{\"rendered_markdown\":\"scoped\"}")),
    ]),
  )
  let scoped_ext = tool_ext(mcp=scoped_mcp, space=Some("team"))
  let scoped = @posoco.ToolProvider::execute(
    scoped_ext,
    "read_context_bundle",
    tool_call("read_context_bundle", Json::object(Map::from_array([]))),
  )
  guard scoped is @posoco.ToolOutcome::Success(content=scoped_content, ..) else {
    fail("expected success")
  }
  inspect(scoped_content, content="scoped")
  inspect(
    json_field(recorded_args(scoped_mcp, 0), "space_id")
    is Some(Json::String("team")),
    content="true",
  )
}

///|
async test "thread tools attach parsed reply text as structured payload" {
  // thread_search: non-JSON reply text keeps structured None, content verbatim.
  let thread_mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([("thread_search", mcp_ok("plain text table"))]),
  )
  let thread = @posoco.ToolProvider::execute(
    tool_ext(mcp=thread_mcp),
    "thread_search",
    tool_call("thread_search", j("{\"query\":\"x\"}")),
  )
  guard thread
    is @posoco.ToolOutcome::Success(
      content=thread_content,
      structured=thread_structured
    ) else {
    fail("expected success")
  }
  inspect(thread_content, content="plain text table")
  inspect(thread_structured is None, content="true")
}

///|
async test "unscripted tool surfaces a reported error instead of hanging" {
  let ext = tool_ext()
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "thread_search",
    tool_call("thread_search", j("{\"query\":\"x\"}")),
  )
  guard outcome is @posoco.ToolOutcome::ToolReportedError(..) else {
    fail("expected a reported error")
  }
  assert_true(outcome_text(outcome).contains("no script for 'thread_search'"))
}
