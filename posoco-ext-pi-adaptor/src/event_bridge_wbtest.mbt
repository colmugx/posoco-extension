///|
/// Whitebox helper: register a payload-capturing handler for one pi event.
extern "js" fn wbtest_on_capture(
  host : JsPiHost,
  event : String,
  capture : (String) -> Unit,
) -> Unit =
  #| (host, event, capture) => {
  #|   const list = host.state.handlers.get(event) ?? [];
  #|   list.push((payload) => { capture(JSON.stringify(payload)); });
  #|   host.state.handlers.set(event, list);
  #| }

///|
/// Macrotask boundary: every fire-and-forget emit scheduled before it has
/// fully drained (sync handlers run inside the emit's first microtask).
extern "js" fn wbtest_settle_promise() -> JsPromise =
  #| () => new Promise((resolve) => setTimeout(() => resolve("settled"), 0))

///|
extern "js" fn wbtest_push_updating_tool(host : JsPiHost) -> Unit =
  #| (host) => {
  #|   const tool = {
  #|     name: "updater",
  #|     description: "wbtest",
  #|     parameters: { type: "object", properties: {} },
  #|     async execute(callId, params, signal, onUpdate) {
  #|       onUpdate({ progress: 1 });
  #|       return { content: [{ type: "text", text: "done" }] };
  #|     },
  #|   };
  #|   host.state.tools.push(tool);
  #|   host.state.byName.set(tool.name, tool);
  #| }

///|
fn wbtest_register(adaptor : PiAdaptor, captured : Array[String], name : String) -> Unit {
  wbtest_on_capture(adaptor.host, name, fn(payload : String) {
    captured.push(name + "|" + payload)
  })
}

///|
let wbtest_family : Array[String] = [
  "agent_start", "turn_start", "message_start", "message_update",
  "message_end", "tool_execution_start", "tool_execution_end",
  "turn_end", "agent_end", "agent_settled",
]

///|
fn wbtest_count(captured : Array[String], name : String) -> Int {
  captured.filter(fn(entry) { entry.contains(name + "|") }).length()
}

///|
async test "event bridge projects posoco turn events into pi handler payloads" {
  let adaptor = pi_adaptor_new()
  let captured : Array[String] = []
  for name in wbtest_family {
    wbtest_register(adaptor, captured, name)
  }
  let observer : &@posoco.Observer = adaptor.events as &@posoco.Observer
  let call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("call-1"),
    name: @kernel.ToolName::unchecked("ping"),
    arguments: Json::object(Map::from_array([("text", Json::string("hi"))])),
  }
  let events : Array[@posoco.TurnEvent] = [
    TurnStarted,
    StreamChunkReceived(
      chunk=@posoco.StreamChunk::ReasoningDelta(token="hm"),
    ),
    StreamChunkReceived(chunk=@posoco.StreamChunk::TextDelta(token="Hel")),
    StreamChunkReceived(chunk=@posoco.StreamChunk::TextDelta(token="lo")),
    ModelResponseReceived(
      message=@kernel.AssistantMessage(
        content=[@kernel.Text("Hello")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@kernel.Stop,
      ),
      usage=None,
    ),
    ToolCallPending(call),
    ToolCallResult(
      call~,
      result=@kernel.Success(content="pong", structured=None),
      is_error=false,
    ),
    TurnCompleted,
  ]
  for event in events {
    observer.on_event_at(None, event)
  }
  adaptor.events.emit_agent_boundary()
  ignore(wait_js_string(wbtest_settle_promise()))
  inspect(captured.length(), content="12")
  // agent_start precedes turn_start (pi resets turnIndex on agent_start).
  inspect(captured[0], content="agent_start|{}")
  inspect(captured[1].contains("\"turnIndex\":0"), content="true")
  inspect(captured[1].contains("\"timestamp\":"), content="true")
  inspect(captured[2].contains("\"role\":\"assistant\""), content="true")
  inspect(
    captured[3].contains("\"type\":\"thinking_delta\"") &&
    captured[3].contains("\"delta\":\"hm\""),
    content="true",
  )
  inspect(
    captured[4].contains("\"type\":\"text_delta\"") &&
    captured[4].contains("\"delta\":\"Hel\"") &&
    captured[4].contains("\"contentIndex\":1"),
    content="true",
  )
  inspect(
    captured[6].contains("\"text\":\"Hello\"") &&
    captured[6].contains("\"stopReason\":\"stop\""),
    content="true",
  )
  inspect(
    captured[7].contains("\"toolCallId\":\"call-1\"") &&
    captured[7].contains("\"toolName\":\"ping\"") &&
    captured[7].contains("\"args\":{\"text\":\"hi\"}"),
    content="true",
  )
  inspect(
    captured[8].contains("\"result\":\"pong\"") &&
    captured[8].contains("\"isError\":false"),
    content="true",
  )
  inspect(
    captured[9].contains("\"turnIndex\":0") &&
    captured[9].contains("\"role\":\"toolResult\"") &&
    captured[9].contains("\"pong\""),
    content="true",
  )
  inspect(
    captured[10].contains("\"messages\":[") &&
    captured[10].contains("\"Hello\"") &&
    captured[10].contains("\"pong\""),
    content="true",
  )
  inspect(captured[11], content="agent_settled|{}")
}

///|
async test "agent run spans follow-up turns until the host boundary" {
  let adaptor = pi_adaptor_new()
  let captured : Array[String] = []
  for name in wbtest_family {
    wbtest_register(adaptor, captured, name)
  }
  let observer : &@posoco.Observer = adaptor.events as &@posoco.Observer
  // Turn 1 of the run.
  observer.on_event_at(None, TurnStarted)
  observer.on_event_at(None, TurnCompleted)
  // A drained follow-up turn continues the same agent run: no agent_start,
  // and pi's turnIndex advances.
  observer.on_event_at(None, TurnStarted)
  observer.on_event_at(None, TurnCompleted)
  adaptor.events.emit_agent_boundary()
  // The next user prompt starts a fresh agent run.
  observer.on_event_at(None, TurnStarted)
  // A failed turn ends the run without turn_end and without agent_settled.
  observer.on_event_at(None, TurnFailed("model exploded"))
  ignore(wait_js_string(wbtest_settle_promise()))
  // Order: agent_start, turn_start(0), turn_end(0), turn_start(1), turn_end(1),
  // agent_end, agent_settled, agent_start, turn_start(0), agent_end.
  inspect(wbtest_count(captured, "agent_start").to_string(), content="2")
  inspect(wbtest_count(captured, "turn_start").to_string(), content="3")
  inspect(
    captured[1].contains("\"turnIndex\":0") &&
    captured[3].contains("\"turnIndex\":1") &&
    captured[8].contains("\"turnIndex\":0"),
    content="true",
  )
  inspect(
    captured[5].contains("agent_end|") &&
    captured[5].contains("\"messages\":[]"),
    content="true",
  )
  inspect(
    captured[9].contains("agent_end|") &&
    captured[9].contains("\"messages\":[]"),
    content="true",
  )
  inspect(wbtest_count(captured, "agent_settled").to_string(), content="1")
  inspect(wbtest_count(captured, "turn_end").to_string(), content="2")
}

///|
async test "tool updates emit tool_execution_update directly with the call" {
  let adaptor = pi_adaptor_new()
  wbtest_push_updating_tool(adaptor.host)
  let captured : Array[String] = []
  wbtest_register(adaptor, captured, "tool_execution_update")
  let result = wait_js_string(
    js_execute_async(adaptor.host, "updater", "call-9", "{}"),
  )
  inspect(result.contains("\"ok\":true"), content="true")
  inspect(captured.length(), content="1")
  inspect(
    captured[0].contains("\"toolCallId\":\"call-9\"") &&
    captured[0].contains("\"toolName\":\"updater\"") &&
    captured[0].contains("\"partialResult\":{\"progress\":1}"),
    content="true",
  )
  // The legacy state.updates capture still works alongside the direct emit.
  inspect(js_updates_json(adaptor.host).contains("call-9"), content="true")
}
