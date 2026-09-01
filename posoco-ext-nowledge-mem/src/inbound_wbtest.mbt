///|
/// Text of the injected session-opening memory message in a payload (core's
/// lead line plus this extension's envelope inside it); `None` when core
/// injected nothing.
fn injected_memory_text(messages : Array[@posoco.Message]) -> String? {
  for message in messages {
    match message {
      @posoco.Message::UserMessage(content~) =>
        match content {
          [@posoco.Content::Text(text), ..] =>
            if text.has_prefix(@posoco.MEMORY_INBOUND_LEAD) {
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
/// How many injected memory messages a payload carries.
fn injected_memory_count(messages : Array[@posoco.Message]) -> Int {
  let mut count = 0
  for message in messages {
    if is_injected_memory_message(message) {
      count = count + 1
    }
  }
  count
}

///|
/// One inbound read: the complete message body this extension owns — its
/// `<nmem-context>` envelope around the working-memory snapshot — with the
/// ambient scope and host identity on the MCP call. Core injects it
/// verbatim behind its own lead line.
async test "inbound: reads working memory into the nmem-context envelope" {
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
  guard ext.inbound(session_id="s1", request="how do I ship the zephyr widget")
    is Some(body) else {
    fail("expected an inbound body")
  }
  // Core's lead already opens the memory section, so the body carries no
  // "## Memory" header of its own.
  assert_true(
    body.has_prefix("<nmem-context type=\"memory\" trust=\"false\">\n"),
  )
  assert_false(body.contains("## Memory"))
  assert_true(body.contains("deploy via the staging pipeline"))
  assert_true(body.has_suffix("</nmem-context>"))
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
}

///|
async test "inbound: plain-text working memory degrades to the raw content" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_working_memory", mcp_ok("# Working Memory\n- ship it")),
    ]),
  )
  let ext = nmem_ext(mcp~)
  ext.config = Some(lane_config())
  guard ext.inbound(session_id="s1", request="q") is Some(body) else {
    fail("expected an inbound body")
  }
  assert_true(body.contains("# Working Memory\n- ship it"))
}

///|
async test "inbound: exists false is a clean miss, not a failure" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_working_memory", mcp_ok("{\"exists\":false}")),
    ]),
  )
  let ext = nmem_ext(mcp~)
  ext.config = Some(lane_config())
  inspect(ext.inbound(session_id="s1", request="q") is None, content="true")
  inspect(ext.mem.last_error is None, content="true")
}

///|
async test "inbound: failed read records last_error and raises Inbound" {
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      ("read_working_memory", FakeMcpEntry::Fail("connect refused")),
    ]),
  )
  let ext = nmem_ext(mcp~)
  ext.config = Some(lane_config())
  try ext.inbound(session_id="s1", request="q") catch {
    @posoco.MemoryError::Inbound(reason) =>
      assert_true(reason.contains("connect refused"))
    _ => fail("expected MemoryError::Inbound")
  } noraise {
    _ => fail("expected inbound to raise")
  }
  guard ext.mem.last_error is Some(err) else {
    fail("expected last_error to be recorded")
  }
  assert_true(err.contains("inbound read failed"))
  assert_true(err.contains("connect refused"))
}

///|
async test "inbound: a server-flagged error records detail and raises Inbound" {
  let ext = nmem_ext(
    mcp=FakeNmemMcp::FakeNmemMcp(
      script=Map::from_array([
        ("read_working_memory", mcp_server_error("working memory exploded")),
      ]),
    ),
  )
  ext.config = Some(lane_config())
  try ext.inbound(session_id="s1", request="q") catch {
    @posoco.MemoryError::Inbound(reason) =>
      assert_true(reason.contains("working memory exploded"))
    _ => fail("expected MemoryError::Inbound")
  } noraise {
    _ => fail("expected inbound to raise")
  }
  guard ext.mem.last_error is Some(err) else {
    fail("expected last_error to be recorded")
  }
  assert_true(err.contains("working memory exploded"))
}

///|
async test "inbound: oversized working memory truncates with the host-labeled note" {
  let long = repeat_text("x", 25000)
  let mcp = FakeNmemMcp::FakeNmemMcp(
    script=Map::from_array([
      (
        "read_working_memory",
        mcp_ok("{\"exists\":true,\"content\":\"\{long}\"}"),
      ),
    ]),
  )
  let ext = nmem_ext(mcp~)
  ext.config = Some(lane_config())
  guard ext.inbound(session_id="s1", request="q") is Some(body) else {
    fail("expected an inbound body")
  }
  assert_true(
    body.contains("[Nowledge Mem context truncated by Posoco plugin]"),
  )
  assert_true(body.length() < 21000)
}

///|
/// is_injected_memory_message recognizes core's injected memory message by
/// its lead line; plain user speech never matches.
test "is_injected_memory_message: the core lead prefix hits, plain input does not" {
  let injected : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(
      @posoco.MEMORY_INBOUND_LEAD +
      "\n\n<nmem-context type=\"memory\" trust=\"false\">fact</nmem-context>",
    ),
  ])
  inspect(is_injected_memory_message(injected), content="true")
  let plain = @posoco.tk_user_msg("hello there")
  inspect(is_injected_memory_message(plain), content="false")
  let reply = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text(@posoco.MEMORY_INBOUND_LEAD + " echoed")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
  inspect(is_injected_memory_message(reply), content="false")
}
