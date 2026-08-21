///|
/// Whitebox tests for the ACP bridge: pure projections, the event→update
/// queue pipeline, and the permission gate.

// ---------------------------------------------------------------- fixtures

///|
/// Recording stand-in for the ACP client side. The brokers capture every
/// typed notification and request; permission and elicitation replies are
/// scripted.
priv struct FakeAcpClient {
  sent : Array[@acp.SessionUpdateParams]
  asked : Array[@acp.RequestPermissionRequest]
  reply : @acp.RequestPermissionResponse
  fail_permission : Bool
  elicitations : Array[@acp.ElicitationCreateParams]
  elicit_reply : @acp.ElicitationCreateResult
  mut fail_elicitation : @acp.AgentContextError?
}

///|
fn FakeAcpClient::FakeAcpClient(
  reply? : @acp.RequestPermissionResponse = {
    outcome: Selected({ option_id: ACP_ALLOW_ONCE, meta: Omitted }),
    meta: Omitted,
  },
  fail_permission? : Bool = false,
  elicit_reply? : @acp.ElicitationCreateResult = {
    action: Accept,
    content: Omitted,
    meta: Omitted,
  },
) -> FakeAcpClient {
  {
    sent: [],
    asked: [],
    reply,
    fail_permission,
    elicitations: [],
    elicit_reply,
    fail_elicitation: None,
  }
}

///|
fn elicit_accept_value(value : Json) -> @acp.ElicitationCreateResult {
  { action: Accept, content: Value(value), meta: Omitted }
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
        ElicitationCreate(params) => {
          client.elicitations.push(params)
          match client.fail_elicitation {
            Some(error) => Err(error)
            None => Ok(AgentReplyElicitationCreate(client.elicit_reply))
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
  let request = acp_permission_request("session-1", {
    tool_name: "edit",
    call_id: "c9",
    category: "write",
    arguments_preview: "{\"file_path\":\"a.txt\"}",
    arguments: Json::object({ "file_path": Json::string("a.txt") }),
  })
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
test "acp_decision_from_approval maps allow, deny, and cancel" {
  let ask : @permission.ApprovalRequest = tk_approval("bash")
  assert_true(
    acp_decision_from_approval(
      {
        outcome: Selected({ option_id: ACP_ALLOW_ONCE, meta: Omitted }),
        meta: Omitted,
      },
      ask,
    )
    is @permission.ApprovalDecision::AllowOnce,
  )
  assert_true(
    acp_decision_from_approval(
      {
        outcome: Selected({ option_id: ACP_ALLOW_ALWAYS, meta: Omitted }),
        meta: Omitted,
      },
      ask,
    )
    is @permission.ApprovalDecision::AllowAlways,
  )
  match
    acp_decision_from_approval(
      {
        outcome: Selected({ option_id: ACP_REJECT_ONCE, meta: Omitted }),
        meta: Omitted,
      },
      ask,
    ) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_eq(reason, "acp: client denied tool 'bash' (option reject-once)")
    _ => fail("expected deny")
  }
  assert_true(
    acp_decision_from_approval({ outcome: Cancelled, meta: Omitted }, ask)
    is @permission.ApprovalDecision::Deny(_),
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

// -------------------------------------------------------- approval source

///|
/// Approval ask fixture: the parsed shape PermissionPolicy hands the bridge.
fn tk_approval(
  name : String,
  id? : String = "call-1",
) -> @permission.ApprovalRequest {
  {
    tool_name: name,
    call_id: id,
    category: "unknown",
    arguments_preview: "{}",
    arguments: Json::object({}),
  }
}

///|
async test "ask flushes, translates, and allows once on allow-once" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient()
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  bridge.ingest(ToolCallPending(tk_call("edit", id="c1")))
  match bridge.ask(tk_approval("edit", id="c1")) {
    @permission.ApprovalDecision::AllowOnce => ()
    _ => fail("expected AllowOnce")
  }
  // The pending announcement was flushed before the permission request, and
  // the request carried the full parsed arguments as raw_input.
  assert_eq(client.sent.length(), 1)
  assert_eq(client.asked.length(), 1)
  assert_eq(client.asked[0].session_id, "s1")
  assert_eq(client.asked[0].tool_call.raw_input, Value(Json::object({})))
}

///|
async test "ask maps allow-always onto the policy-cacheable decision" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(reply={
    outcome: Selected({ option_id: ACP_ALLOW_ALWAYS, meta: Omitted }),
    meta: Omitted,
  })
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  match bridge.ask(tk_approval("edit")) {
    @permission.ApprovalDecision::AllowAlways => ()
    _ => fail("expected AllowAlways")
  }
}

///|
async test "ask denies on reject and keeps the option id in the reason" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(reply={
    outcome: Selected({ option_id: ACP_REJECT_ALWAYS, meta: Omitted }),
    meta: Omitted,
  })
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  match bridge.ask(tk_approval("bash")) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_eq(reason, "acp: client denied tool 'bash' (option reject-always)")
    _ => fail("expected deny")
  }
}

///|
async test "ask denies when the client cancels" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(reply={
    outcome: Cancelled,
    meta: Omitted,
  })
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  match bridge.ask(tk_approval("bash")) {
    @permission.ApprovalDecision::Deny(_) => ()
    _ => fail("expected deny")
  }
}

///|
async test "ask fails closed on broker error" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(fail_permission=true)
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  match bridge.ask(tk_approval("bash")) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_eq(
        reason, "acp: permission request for tool 'bash' failed; failing closed",
      )
    _ => fail("expected deny")
  }
}

///|
async test "detached bridge approves every ask without asking" {
  let bridge = AcpBridge::new()
  match bridge.ask(tk_approval("bash")) {
    @permission.ApprovalDecision::AllowOnce => ()
    _ => fail("expected AllowOnce while detached")
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

// ------------------------------------------------------------ UiPort (elicitation)

///|
async test "ui select request maps to an enum form and back to an index" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(
    elicit_reply=elicit_accept_value(
      Json::object({ "value": Json::string("second") }),
    ),
  )
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  let req : @posoco.UiRequest = Select(
    prompt="Which database?",
    options=["first", "second", "third"],
    default=Some(1),
  )
  let resp = bridge.request(req)
  assert_true(resp is @posoco.UiResponse::Selected(1))
  assert_eq(client.elicitations.length(), 1)
  match client.elicitations[0] {
    Form({ scope: Session(session_id~, ..), message, requested_schema, .. }) => {
      assert_eq(session_id, "s1")
      assert_eq(message, "Which database?")
      json_inspect(requested_schema, content={
        "type": "object",
        "properties": {
          "value": {
            "type": "string",
            "enum": ["first", "second", "third"],
            "default": "second",
          },
        },
        "required": ["value"],
      })
    }
    _ => fail("expected form-mode elicitation")
  }
}

///|
async test "ui input request maps to a string form with pre-fill" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(
    elicit_reply=elicit_accept_value(
      Json::object({ "value": Json::string("v1") }),
    ),
  )
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  let resp = bridge.request(Input(prompt="Branch name?", default=Some("main")))
  assert_eq(resp, @posoco.UiResponse::Text("v1"))
  match client.elicitations[0] {
    Form({ requested_schema, .. }) =>
      json_inspect(requested_schema, content={
        "type": "object",
        "properties": { "value": { "type": "string", "default": "main" } },
        "required": ["value"],
      })
    _ => fail("expected form-mode elicitation")
  }
}

///|
async test "ui confirm request maps to a boolean form yes/no" {
  let bridge = AcpBridge::new()
  let yes_client = FakeAcpClient::FakeAcpClient(
    elicit_reply=elicit_accept_value(
      Json::object({ "value": Json::boolean(true) }),
    ),
  )
  bridge.attach(context=fake_acp_context(yes_client), session_id="s1")
  assert_eq(
    bridge.request(Confirm(prompt="Deploy now?")),
    @posoco.UiResponse::Yes,
  )
  let no_client = FakeAcpClient::FakeAcpClient(
    elicit_reply=elicit_accept_value(
      Json::object({ "value": Json::boolean(false) }),
    ),
  )
  bridge.attach(context=fake_acp_context(no_client), session_id="s1")
  assert_eq(
    bridge.request(Confirm(prompt="Deploy now?")),
    @posoco.UiResponse::No,
  )
}

///|
async test "declined and cancelled elicitations map to Cancelled" {
  let bridge = AcpBridge::new()
  let declined = FakeAcpClient::FakeAcpClient(elicit_reply={
    action: Decline,
    content: Omitted,
    meta: Omitted,
  })
  bridge.attach(context=fake_acp_context(declined), session_id="s1")
  assert_eq(
    bridge.request(Input(prompt="Anything?", default=None)),
    @posoco.UiResponse::Cancelled,
  )
  let cancelled = FakeAcpClient::FakeAcpClient(elicit_reply={
    action: Cancel,
    content: Omitted,
    meta: Omitted,
  })
  bridge.attach(context=fake_acp_context(cancelled), session_id="s1")
  assert_eq(
    bridge.request(Confirm(prompt="Deploy now?")),
    @posoco.UiResponse::Cancelled,
  )
}

///|
async test "detached bridge raises Unsupported" {
  let bridge = AcpBridge::new()
  let outcome : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
    bridge.request(Input(prompt="Anyone?", default=None)),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.UiError::Unsupported(detail~)) =>
      assert_true(detail.contains("detached"))
    _ => fail("expected Unsupported from a detached bridge")
  }
}

///|
async test "elicitation failures map onto the UiError shades" {
  let bridge = AcpBridge::new()
  // Capability gate: the runtime rejects the request outright.
  let no_capability = FakeAcpClient::FakeAcpClient()
  no_capability.fail_elicitation = Some(
    AgentContextUnavailable(method_name="elicitation/create"),
  )
  bridge.attach(context=fake_acp_context(no_capability), session_id="s1")
  let gated : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
    bridge.request(Input(prompt="q", default=None)),
  ) catch {
    error => Err(error)
  }
  match gated {
    Err(@posoco.UiError::Unsupported(detail~)) =>
      assert_true(detail.contains("elicitation"))
    _ => fail("expected Unsupported when the client lacks the capability")
  }
  // Transport failure mid-request.
  let broken = FakeAcpClient::FakeAcpClient()
  broken.fail_elicitation = Some(
    AgentContextBrokerFailure(method_name="elicitation/create"),
  )
  bridge.attach(context=fake_acp_context(broken), session_id="s1")
  let failed : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
    bridge.request(Input(prompt="q", default=None)),
  ) catch {
    error => Err(error)
  }
  match failed {
    Err(@posoco.UiError::IoFailure(detail~)) =>
      assert_true(detail.contains("failed in transit"))
    _ => fail("expected IoFailure from a broken elicitation request")
  }
}

///|
async test "accept with an out-of-enum answer fails loudly" {
  let bridge = AcpBridge::new()
  let client = FakeAcpClient::FakeAcpClient(
    elicit_reply=elicit_accept_value(
      Json::object({ "value": Json::string("fourth") }),
    ),
  )
  bridge.attach(context=fake_acp_context(client), session_id="s1")
  let req : @posoco.UiRequest = Select(
    prompt="Pick one",
    options=["first", "second"],
    default=None,
  )
  let outcome : Result[@posoco.UiResponse, @posoco.UiError] = Ok(
    bridge.request(req),
  ) catch {
    error => Err(error)
  }
  assert_true(outcome is Err(@posoco.UiError::IoFailure(_)))
}

///|
async test "manifest declares the UiPort contribution" {
  let bridge = AcpBridge::new()
  assert_eq(bridge.manifest().ui.length(), 1)
}
