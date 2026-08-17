///|
/// Whitebox tests for the ACP bridge: pure projections, the event→update
/// queue pipeline, and the permission gate.

// ---------------------------------------------------------------- fixtures

///|
/// Recording stand-in for the ACP client side. The brokers capture every
/// typed notification and request; permission replies are scripted.
priv struct FakeAcpClient {
  sent : Array[@acp.SessionUpdateParams]
  asked : Array[@acp.RequestPermissionRequest]
  reply : @acp.RequestPermissionResponse
  fail_permission : Bool
}

///|
fn FakeAcpClient::FakeAcpClient(
  reply? : @acp.RequestPermissionResponse = {
    outcome: Selected({ option_id: ACP_ALLOW_ONCE, meta: Omitted }),
    meta: Omitted,
  },
  fail_permission? : Bool = false,
) -> FakeAcpClient {
  { sent: [], asked: [], reply, fail_permission }
}

///|
/// Build a real acp.mbt `AgentContext` over the recording brokers.
fn fake_acp_context(client : FakeAcpClient) -> @acp.AgentContext {
  @acp.agent_context(
    request_broker=request => {
      match request {
        SessionRequestPermission(ask) => {
          client.asked.push(ask)
          if client.fail_permission {
            Err(
              AgentContextBrokerFailure(
                method_name="session/request_permission",
              ),
            )
          } else {
            Ok(AgentReplyRequestPermission(client.reply))
          }
        }
        _ => Err(AgentContextBrokerFailure(method_name="unused-request"))
      }
    },
    notification_broker=notification => {
      match notification {
        SessionUpdate(params) => {
          client.sent.push(params)
          Ok(())
        }
        _ => Ok(())
      }
    },
  )
}

///|
fn tk_call(
  name : String,
  id? : String = "call-1",
  arguments? : Json = Json::object({}),
) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked(id),
    name: @posoco.ToolName::unchecked(name),
    arguments,
  }
}

///|
fn tk_assistant(
  content? : Array[@posoco.Content] = [],
  tool_calls? : Array[@posoco.ToolCall] = [],
  reasoning? : String = "",
  finish? : @posoco.FinishReason = Stop,
) -> @posoco.Message {
  let reasoning_value : @posoco.Reasoning? = if reasoning == "" {
    None
  } else {
    Some({ content: reasoning, raw: None })
  }
  @posoco.Message::AssistantMessage(
    content~,
    tool_calls~,
    reasoning=reasoning_value,
    finish_reason=finish,
  )
}

///|
fn tk_usage(total : Int) -> @posoco.Usage {
  {
    input_tokens: Some(total - 1),
    output_tokens: Some(1),
    total_tokens: Some(total),
  }
}

///|
/// Ask policy used by the exemption test: read/search/think tools pass.
fn needs_ask(call : @posoco.ToolCall) -> Bool {
  match acp_tool_kind(call.name.to_string()) {
    Read | Search | Think => false
    _ => true
  }
}

// ------------------------------------------------------------ pure helpers

///|
test "acp_tool_kind maps namespaced and plain tool names" {
  assert_eq(acp_tool_kind("read"), Read)
  assert_eq(acp_tool_kind("github__search_issues"), Search)
  assert_eq(acp_tool_kind("bash"), Execute)
  assert_eq(acp_tool_kind("write"), Edit)
  assert_eq(acp_tool_kind("rm"), Delete)
  assert_eq(acp_tool_kind("mv"), Move)
  assert_eq(acp_tool_kind("glob"), Search)
  assert_eq(acp_tool_kind("fetch"), Fetch)
  assert_eq(acp_tool_kind("think"), Think)
  assert_eq(acp_tool_kind("totally_unknown"), Other)
}

///|
test "acp_primary_arg extracts the first known string key" {
  let args = Json::object({
    "path": Json::string("src/main.mbt"),
    "command": Json::string("cargo build"),
  })
  assert_eq(acp_primary_arg(args), Some("src/main.mbt"))
  assert_true(acp_primary_arg(Json::object({})) is None)
  assert_true(
    acp_primary_arg(Json::object({ "path": Json::number(1.0) })) is None,
  )
}

///|
test "acp_tool_title prefers primary arg and stays single-line" {
  assert_eq(
    acp_tool_title(
      tk_call(
        "read",
        arguments=Json::object({ "path": Json::string("src/main.mbt") }),
      ),
    ),
    "read(src/main.mbt)",
  )
  assert_eq(acp_tool_title(tk_call("grep")), "grep")
  assert_eq(
    acp_tool_title(
      tk_call(
        "bash",
        arguments=Json::object({ "command": Json::string("echo a\nb\nc") }),
      ),
    ),
    "bash(echo a b c)",
  )
}

///|
test "acp_content_block maps text and image" {
  assert_eq(
    acp_content_block(@posoco.Content::Text("hi")),
    Text({ annotations: Omitted, text: "hi", meta: Omitted }),
  )
  assert_true(
    acp_content_block(
      @posoco.Content::Image(media_type="image/png", data="AAAA"),
    )
    is Image(_),
  )
  match
    acp_content_block(
      @posoco.Content::Image(media_type="image/png", data="AAAA"),
    ) {
    Image(image) => {
      assert_eq(image.data, "AAAA")
      assert_eq(image.mime_type, "image/png")
    }
    _ => fail("expected image block")
  }
}

///|
test "acp outcome status and text cover every outcome variant" {
  assert_eq(
    acp_outcome_status(Success(content="ok", structured=None)),
    Completed,
  )
  assert_eq(
    acp_outcome_status(ToolReportedError(content="nope", structured=None)),
    Failed,
  )
  assert_true(
    acp_outcome_status(RuntimeFailure(error_category="adapter", message="boom"))
    is Failed,
  )
  assert_true(
    acp_outcome_status(
      NotExecuted(
        reason=UnknownTool,
        original_call_id=@posoco.CallId::unchecked("c"),
      ),
    )
    is Failed,
  )
  assert_eq(
    acp_outcome_text(
      RuntimeFailure(error_category="adapter", message="line1\nline2"),
    ),
    "[adapter] line1 line2",
  )
}

///|
test "acp_stop_reason maps only length to max tokens" {
  assert_true(acp_stop_reason(Some(Length)) is MaxTokens)
  assert_true(acp_stop_reason(Some(Stop)) is EndTurn)
  assert_true(acp_stop_reason(Some(ToolCalls)) is EndTurn)
  assert_true(acp_stop_reason(None) is EndTurn)
}

// ------------------------------------------------- permission request build

///|
test "acp_permission_request mirrors the pending announcement" {
  let request = acp_permission_request(
    "session-1",
    tk_call(
      "edit",
      id="c9",
      arguments=Json::object({ "file_path": Json::string("a.txt") }),
    ),
  )
  assert_eq(request.session_id, "session-1")
  assert_eq(request.tool_call.tool_call_id, "c9")
  assert_true(request.tool_call.kind is Value(Edit))
  assert_true(request.tool_call.status is Value(Pending))
  assert_eq(request.tool_call.title, Value("edit(a.txt)"))
  assert_eq(
    request.tool_call.raw_input,
    Value(Json::object({ "file_path": Json::string("a.txt") })),
  )
  assert_eq(request.options.length(), 4)
  assert_eq(request.options[0].option_id, ACP_ALLOW_ONCE)
  assert_eq(request.options[1].option_id, ACP_ALLOW_ALWAYS)
  assert_eq(request.options[2].option_id, ACP_REJECT_ONCE)
  assert_eq(request.options[3].option_id, ACP_REJECT_ALWAYS)
}

///|
test "acp_decision_from_response maps allow, deny, and cancel" {
  let call = tk_call("bash")
  assert_true(
    acp_decision_from_response(
      {
        outcome: Selected({ option_id: ACP_ALLOW_ONCE, meta: Omitted }),
        meta: Omitted,
      },
      call,
    )
    is Approve(_),
  )
  assert_true(
    acp_decision_from_response(
      {
        outcome: Selected({ option_id: ACP_ALLOW_ALWAYS, meta: Omitted }),
        meta: Omitted,
      },
      call,
    )
    is Approve(_),
  )
  match
    acp_decision_from_response(
      {
        outcome: Selected({ option_id: ACP_REJECT_ONCE, meta: Omitted }),
        meta: Omitted,
      },
      call,
    ) {
    Reject(reason~) =>
      assert_eq(reason, "acp: client denied tool 'bash' (option reject-once)")
    _ => fail("expected reject")
  }
  assert_true(
    acp_decision_from_response({ outcome: Cancelled, meta: Omitted }, call)
    is Reject(_),
  )
}

// -------------------------------------------------------- observer pipeline

///|
async test "flush delivers pending and result sequence with session stamp" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  bridge.ingest(TurnStarted)
  bridge.ingest(ToolCallPending(tk_call("read", id="c1")))
  bridge.ingest(
    ToolCallResult(
      call=tk_call("read", id="c1"),
      result=Success(content="L1: hi", structured=None),
      is_error=false,
    ),
  )
  assert_eq(bridge.flush(), 2)
  assert_eq(client.sent.length(), 2)
  // Announcement: pending status, kind, title, raw input.
  match client.sent[0].update {
    ToolCall(announcement) => {
      assert_eq(announcement.tool_call_id, "c1")
      assert_eq(announcement.title, "read")
      assert_true(announcement.kind is Value(Read))
      assert_true(announcement.status is Value(Pending))
      assert_true(announcement.raw_input is Value(_))
    }
    _ => fail("expected tool call announcement")
  }
  // Completion: completed status with text content.
  match client.sent[1].update {
    ToolCallUpdate(update) => {
      assert_eq(update.tool_call_id, "c1")
      assert_true(update.status is Value(Completed))
      match update.content {
        Value([Content({ content: Text({ text, .. }), .. })]) =>
          assert_eq(text, "L1: hi")
        _ => fail("expected text content")
      }
    }
    _ => fail("expected tool call update")
  }
  // Every frame carries the attached ACP session id.
  for frame in client.sent {
    assert_eq(frame.session_id, "s1")
  }
}

///|
async test "tool failure outcome maps to failed status" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  bridge.ingest(
    ToolCallResult(
      call=tk_call("bash", id="c2"),
      result=ToolReportedError(content="exit 1", structured=None),
      is_error=true,
    ),
  )
  ignore(bridge.flush())
  match client.sent[0].update {
    ToolCallUpdate(update) => {
      assert_true(update.status is Value(Failed))
      match update.content {
        Value([Content({ content: Text({ text, .. }), .. })]) =>
          assert_eq(text, "exit 1")
        _ => fail("expected text content")
      }
    }
    _ => fail("expected tool call update")
  }
}

///|
async test "deferred tool stays pending with a deferred title" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  bridge.ingest(
    ToolCallDeferred(call=tk_call("bash", id="c3"), reason="waiting on host"),
  )
  ignore(bridge.flush())
  match client.sent[0].update {
    ToolCallUpdate(update) => {
      assert_eq(update.tool_call_id, "c3")
      assert_true(update.status is Value(Pending))
      assert_eq(update.title, Value("bash — deferred: waiting on host"))
    }
    _ => fail("expected tool call update")
  }
}

///|
async test "streamed deltas share one message id and suppress final text" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  bridge.ingest(TurnStarted)
  bridge.ingest(StreamChunkReceived(chunk=TextDelta(token="Hel")))
  bridge.ingest(StreamChunkReceived(chunk=TextDelta(token="lo")))
  bridge.ingest(
    ModelResponseReceived(
      message=tk_assistant(
        content=[@posoco.Content::Text("Hello")],
        finish=Stop,
      ),
      usage=None,
    ),
  )
  ignore(bridge.flush())
  assert_eq(client.sent.length(), 2)
  let ids : Array[String?] = []
  for frame in client.sent {
    match frame.update {
      AgentMessageChunk(chunk) => {
        match chunk.content {
          Text({ text, .. }) => assert_true(text == "Hel" || text == "lo")
          _ => fail("expected text block")
        }
        match chunk.message_id {
          Value(id) => ids.push(Some(id))
          _ => ids.push(None)
        }
      }
      _ => fail("expected agent message chunk")
    }
  }
  // Both deltas share one message id: one streamed message, no duplication
  // of the committed text.
  assert_eq(ids[0], ids[1])
  assert_true(ids[0] is Some(_))
}

///|
async test "reasoning deltas stream as thought chunks" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  bridge.ingest(StreamChunkReceived(chunk=ReasoningDelta(token="thinking")))
  bridge.ingest(
    ModelResponseReceived(
      message=tk_assistant(
        content=[@posoco.Content::Text("answer")],
        reasoning="thinking",
      ),
      usage=None,
    ),
  )
  ignore(bridge.flush())
  assert_eq(client.sent.length(), 2)
  assert_true(client.sent[0].update is AgentThoughtChunk(_))
  assert_true(client.sent[1].update is AgentMessageChunk(_))
}

///|
async test "model response projects thought, blocks, and cumulative usage" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  bridge.ingest(TurnStarted)
  // Round one: full non-streamed response with reasoning and usage.
  bridge.ingest(
    ModelResponseReceived(
      message=tk_assistant(
        content=[
          @posoco.Content::Text("plan"),
          @posoco.Content::Image(media_type="image/png", data="AA"),
        ],
        reasoning="let me think",
      ),
      usage=Some(tk_usage(10)),
    ),
  )
  // Round two: only text, more usage — the usage update must accumulate.
  bridge.ingest(
    ModelResponseReceived(
      message=tk_assistant(content=[@posoco.Content::Text("done")]),
      usage=Some(tk_usage(20)),
    ),
  )
  ignore(bridge.flush())
  // thought, text, image, usage, text, usage
  assert_eq(client.sent.length(), 6)
  assert_true(client.sent[0].update is AgentThoughtChunk(_))
  assert_true(client.sent[1].update is AgentMessageChunk(_))
  assert_true(client.sent[2].update is AgentMessageChunk(_))
  match client.sent[3].update {
    UsageUpdate(usage) => assert_eq(usage.used, 10)
    _ => fail("expected usage update")
  }
  match client.sent[5].update {
    UsageUpdate(usage) => assert_eq(usage.used, 30)
    _ => fail("expected usage update")
  }
  // A tool-loop round re-projects text (per-round streaming state resets).
  match client.sent[4].update {
    AgentMessageChunk(chunk) =>
      assert_true(chunk.content is Text({ text: "done", .. }))
    _ => fail("expected agent message chunk")
  }
}

///|
async test "turn failure is recorded once and consumed by the host" {
  let bridge = AcpBridge::new()
  bridge.ingest(TurnStarted)
  assert_true(bridge.take_failure() is None)
  bridge.ingest(TurnFailed("model unavailable"))
  assert_eq(bridge.take_failure(), Some("model unavailable"))
  assert_true(bridge.take_failure() is None)
  // A new turn clears any stale failure.
  bridge.ingest(TurnFailed("stale"))
  bridge.ingest(TurnStarted)
  assert_true(bridge.take_failure() is None)
}

///|
async test "stop reason follows the last observed finish reason" {
  let bridge = AcpBridge::new()
  assert_true(bridge.stop_reason() is EndTurn)
  bridge.ingest(
    ModelResponseReceived(
      message=tk_assistant(content=[], finish=Length),
      usage=None,
    ),
  )
  assert_true(bridge.stop_reason() is MaxTokens)
}

///|
async test "flush before attach sends nothing and keeps items queued" {
  let bridge = AcpBridge::new()
  bridge.ingest(ToolCallPending(tk_call("read")))
  assert_eq(bridge.flush(), 0)
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="late")
  assert_eq(bridge.flush(), 1)
  assert_eq(client.sent[0].session_id, "late")
}

///|
async test "detach stops delivery" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  bridge.detach()
  bridge.ingest(ToolCallPending(tk_call("read")))
  assert_eq(bridge.flush(), 0)
  assert_eq(client.sent.length(), 0)
}

// ------------------------------------------------------------ permission gate

///|
async test "before_tool flushes, asks, and approves on allow" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  bridge.ingest(ToolCallPending(tk_call("edit", id="c1")))
  match bridge.before_tool(tk_call("edit", id="c1")) {
    Approve(..) => ()
    _ => fail("expected approve")
  }
  // The pending announcement was flushed before the permission request.
  assert_eq(client.sent.length(), 1)
  assert_eq(client.asked.length(), 1)
  assert_eq(client.asked[0].session_id, "s1")
}

///|
async test "before_tool rejects on deny" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(reply={
    outcome: Selected({ option_id: ACP_REJECT_ALWAYS, meta: Omitted }),
    meta: Omitted,
  })
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  match bridge.before_tool(tk_call("bash")) {
    Reject(reason~) =>
      assert_eq(reason, "acp: client denied tool 'bash' (option reject-always)")
    _ => fail("expected reject")
  }
}

///|
async test "before_tool rejects when the client cancels" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(reply={
    outcome: Cancelled,
    meta: Omitted,
  })
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  match bridge.before_tool(tk_call("bash")) {
    Reject(_) => ()
    _ => fail("expected reject")
  }
}

///|
async test "before_tool fails closed on broker error" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(fail_permission=true)
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  match bridge.before_tool(tk_call("bash")) {
    Reject(reason~) =>
      assert_eq(
        reason, "acp: permission request for tool 'bash' failed; failing closed",
      )
    _ => fail("expected reject")
  }
}

///|
async test "exempt tools skip the permission round-trip" {
  let bridge = AcpBridge::new(needs_permission=needs_ask)
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  match bridge.before_tool(tk_call("read")) {
    Approve(..) => ()
    _ => fail("expected approve")
  }
  assert_eq(client.asked.length(), 0)
  match bridge.before_tool(tk_call("bash")) {
    // The fake client's scripted reply allows, so bash approves — the point
    // is that it went through the permission round-trip at all.
    Approve(..) => ()
    _ => fail("expected scripted-allow approve")
  }
  assert_eq(client.asked.length(), 1)
}

///|
async test "detached bridge approves without asking" {
  let bridge = AcpBridge::new()
  match bridge.before_tool(tk_call("bash")) {
    Approve(..) => ()
    _ => fail("expected approve")
  }
}

// --------------------------------------------------------------------- pump

///|
async test "spawn_pump forwards updates concurrently and stops on close" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  @async.with_task_group(group => {
    bridge.spawn_pump(group)
    bridge.ingest(ToolCallPending(tk_call("read", id="c1")))
    @async.pause()
    assert_eq(client.sent.length(), 1)
    bridge.close()
  })
}

///|
async test "close then attach reopens the queue for the next prompt" {
  let bridge = AcpBridge::new()
  let first = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(first), session_id="s1")
  @async.with_task_group(group => {
    bridge.spawn_pump(group)
    bridge.ingest(ToolCallPending(tk_call("read", id="c1")))
    bridge.close()
  })
  // Events enqueued while closed are dropped...
  bridge.ingest(ToolCallPending(tk_call("read", id="c2")))
  assert_eq(first.sent.length(), 1)
  // ...and the next attach delivers a fresh queue to the next client.
  let second = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(second), session_id="s2")
  bridge.ingest(ToolCallPending(tk_call("read", id="c3")))
  assert_eq(bridge.flush(), 1)
  assert_eq(second.sent.length(), 1)
  assert_eq(second.sent[0].session_id, "s2")
}
