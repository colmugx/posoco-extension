///|
/// Pi lifecycle-event bridge: projects posoco Observer turn events onto the
/// shared JS host's pi `on(event, handler)` families (agent / turn / message
/// / tool_execution). One observer per PiAdaptor. pi semantics keep an agent
/// run open across queued follow-up turns, so the host owns the run boundary
/// via `emit_agent_boundary`.
pub struct PiEventObserver {
  host : JsPiHost
  mut run_active : Bool
  /// pi turnIndex: 0-based per agent run, advanced after each turn_end.
  mut turn_index : Int
  mut message_started : Bool
  mut text_started : Bool
  mut thinking_started : Bool
  mut text_buf : StringBuilder
  mut thinking_buf : StringBuilder
  /// Serialized assistant message of the current turn (turn_end payload).
  mut last_assistant : Json?
  /// toolResult messages accumulated during the current turn.
  mut turn_tool_results : Array[Json]
  /// assistant + toolResult messages accumulated during the current run.
  mut run_messages : Array[Json]
}

///|
pub fn PiEventObserver::PiEventObserver(host~ : JsPiHost) -> PiEventObserver {
  {
    host,
    run_active: false,
    turn_index: 0,
    message_started: false,
    text_started: false,
    thinking_started: false,
    text_buf: StringBuilder(),
    thinking_buf: StringBuilder(),
    last_assistant: None,
    turn_tool_results: [],
    run_messages: [],
  }
}

///|
/// Fire-and-forget only: Observer callbacks are synchronous trait methods, so
/// the foreign emit promise must never be awaited here.
extern "js" fn js_promise_ignore(promise : JsPromise) -> Unit =
  #| (promise) => {
  #|   promise.then(() => {}, () => {});
  #| }

///|
extern "js" fn js_now_ms() -> Double =
  #| () => Date.now()

///|
fn PiEventObserver::emit(
  self : PiEventObserver,
  event : String,
  payload : Json,
) -> Unit {
  js_promise_ignore(js_emit_event(self.host, event, payload.stringify()))
}

///|
fn pi_content_json(c : @kernel.Content) -> Json {
  match c {
    @kernel.Text(text) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("text")),
          ("text", Json::string(text)),
        ]),
      )
    @kernel.Image(media_type~, data~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("image")),
          ("data", Json::string(data)),
          ("mimeType", Json::string(media_type)),
        ]),
      )
  }
}

///|
fn pi_thinking_json(thinking : String) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("thinking")),
      ("thinking", Json::string(thinking)),
    ]),
  )
}

///|
fn pi_stop_reason(finish : @kernel.FinishReason) -> String {
  match finish {
    @kernel.Stop => "stop"
    @kernel.Length => "length"
    @kernel.ToolCalls => "toolUse"
    @kernel.Other(reason) => reason
  }
}

///|
fn outcome_text(outcome : @kernel.ToolOutcome) -> String {
  match outcome {
    @kernel.Success(content~, ..) => content
    @kernel.ToolReportedError(content~, ..) => content
    @kernel.RuntimeFailure(message~, ..) => message
    @kernel.NotExecuted(..) => "not executed"
  }
}

///|
/// Minimal pi-shaped message serializer (role + content parts): enough for
/// the message_*/turn_end/agent_end payloads; W4 extends it.
fn pi_message_json(msg : @kernel.Message) -> Json {
  match msg {
    @kernel.SystemMessage(content~) => {
      let parts : Array[Json] = []
      for c in content {
        parts.push(pi_content_json(c))
      }
      Json::object(
        Map::from_array([
          ("role", Json::string("system")),
          ("content", Json::array(parts)),
        ]),
      )
    }
    @kernel.UserMessage(content~) => {
      let parts : Array[Json] = []
      for c in content {
        parts.push(pi_content_json(c))
      }
      Json::object(
        Map::from_array([
          ("role", Json::string("user")),
          ("content", Json::array(parts)),
        ]),
      )
    }
    @kernel.AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) => {
      let parts : Array[Json] = []
      match reasoning {
        Some(r) => parts.push(pi_thinking_json(r.content))
        None => ()
      }
      for c in content {
        parts.push(pi_content_json(c))
      }
      for tc in tool_calls {
        parts.push(
          Json::object(
            Map::from_array([
              ("type", Json::string("toolCall")),
              ("id", Json::string(tc.call_id.to_string())),
              ("name", Json::string(tc.name.to_string())),
              ("arguments", tc.arguments),
            ]),
          ),
        )
      }
      Json::object(
        Map::from_array([
          ("role", Json::string("assistant")),
          ("content", Json::array(parts)),
          ("stopReason", Json::string(pi_stop_reason(finish_reason))),
          ("timestamp", Json::number(js_now_ms())),
        ]),
      )
    }
    @kernel.ToolMessage(call_id~, tool_name~, outcome~) =>
      Json::object(
        Map::from_array([
          ("role", Json::string("toolResult")),
          ("toolCallId", Json::string(call_id.to_string())),
          ("toolName", Json::string(tool_name.to_string())),
          (
            "content",
            Json::array([pi_content_json(@kernel.Text(outcome_text(outcome)))]),
          ),
          ("isError", Json::boolean(outcome.is_failure())),
          ("timestamp", Json::number(js_now_ms())),
        ]),
      )
  }
}

///|
fn PiEventObserver::reset_response(self : PiEventObserver) -> Unit {
  self.message_started = false
  self.text_started = false
  self.thinking_started = false
  self.text_buf = StringBuilder()
  self.thinking_buf = StringBuilder()
}

///|
fn PiEventObserver::response_json(self : PiEventObserver) -> Json {
  let parts : Array[Json] = []
  if self.thinking_started {
    parts.push(pi_thinking_json(self.thinking_buf.to_string()))
  }
  if self.text_started {
    parts.push(
      Json::object(
        Map::from_array([
          ("type", Json::string("text")),
          ("text", Json::string(self.text_buf.to_string())),
        ]),
      ),
    )
  }
  Json::object(
    Map::from_array([
      ("role", Json::string("assistant")),
      ("content", Json::array(parts)),
      ("stopReason", Json::string("pending")),
      ("timestamp", Json::number(js_now_ms())),
    ]),
  )
}

///|
fn PiEventObserver::ensure_message_started(self : PiEventObserver) -> Unit {
  if self.message_started {
    return
  }
  self.message_started = true
  self.emit(
    "message_start",
    Json::object(Map::from_array([("message", self.response_json())])),
  )
}

///|
fn PiEventObserver::emit_message_update(
  self : PiEventObserver,
  kind : String,
  delta : String,
) -> Unit {
  let content_index = if kind == "text_delta" && self.thinking_started {
    1
  } else {
    0
  }
  self.emit(
    "message_update",
    Json::object(
      Map::from_array([
        ("message", self.response_json()),
        (
          "assistantMessageEvent",
          Json::object(
            Map::from_array([
              ("type", Json::string(kind)),
              ("contentIndex", Json::number(content_index.to_double())),
              ("delta", Json::string(delta)),
            ]),
          ),
        ),
      ]),
    ),
  )
}

///|
pub impl @posoco.Observer for PiEventObserver with fn on_event_at(
  self : PiEventObserver,
  _scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => {
      if !self.run_active {
        self.run_active = true
        self.turn_index = 0
        self.run_messages = []
        self.emit("agent_start", Json::object(Map::from_array([])))
      }
      self.reset_response()
      self.turn_tool_results = []
      self.last_assistant = None
      self.emit(
        "turn_start",
        Json::object(
          Map::from_array([
            ("turnIndex", Json::number(self.turn_index.to_double())),
            ("timestamp", Json::number(js_now_ms())),
          ]),
        ),
      )
    }
    // ToolCallDelta / Usage / Finish carry no pi message_update projection
    // in W1: argument streaming waits on W4's serializer foundation.
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) => {
          self.ensure_message_started()
          self.text_buf.write_string(token)
          self.text_started = true
          self.emit_message_update("text_delta", token)
        }
        @posoco.StreamChunk::ReasoningDelta(token~) => {
          self.ensure_message_started()
          self.thinking_buf.write_string(token)
          self.thinking_started = true
          self.emit_message_update("thinking_delta", token)
        }
        _ => ()
      }
    @posoco.TurnEvent::ModelResponseReceived(message~, usage~) => {
      ignore(usage)
      let serialized = pi_message_json(message)
      self.last_assistant = Some(serialized)
      self.run_messages.push(serialized)
      self.emit(
        "message_end",
        Json::object(Map::from_array([("message", serialized)])),
      )
      self.reset_response()
    }
    @posoco.TurnEvent::ToolCallPending(call) =>
      self.emit(
        "tool_execution_start",
        Json::object(
          Map::from_array([
            ("toolCallId", Json::string(call.call_id.to_string())),
            ("toolName", Json::string(call.name.to_string())),
            ("args", call.arguments),
          ]),
        ),
      )
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) => {
      self.emit(
        "tool_execution_end",
        Json::object(
          Map::from_array([
            ("toolCallId", Json::string(call.call_id.to_string())),
            ("toolName", Json::string(call.name.to_string())),
            ("result", Json::string(outcome_text(result))),
            ("isError", Json::boolean(is_error)),
          ]),
        ),
      )
      let tool_result = pi_message_json(
        @kernel.ToolMessage(
          call_id=call.call_id,
          tool_name=call.name,
          outcome=result,
        ),
      )
      self.turn_tool_results.push(tool_result)
      self.run_messages.push(tool_result)
    }
    @posoco.TurnEvent::TurnCompleted => {
      let message = match self.last_assistant {
        Some(json) => json
        None => Json::null()
      }
      self.emit(
        "turn_end",
        Json::object(
          Map::from_array([
            ("turnIndex", Json::number(self.turn_index.to_double())),
            ("message", message),
            ("toolResults", Json::array(self.turn_tool_results.copy())),
          ]),
        ),
      )
      self.turn_index = self.turn_index + 1
      self.turn_tool_results = []
      self.last_assistant = None
    }
    // pi ends a failed agent loop without a turn_end; W1 reports an empty
    // message list (full run transcript waits on W4's serializer foundation).
    @posoco.TurnEvent::TurnFailed(_) => {
      self.emit(
        "agent_end",
        Json::object(Map::from_array([("messages", Json::array([]))])),
      )
      self.run_active = false
      self.run_messages = []
      self.reset_response()
    }
    _ => ()
  }
}

///|
pub impl @posoco.Observer for PiEventObserver with fn on_event(
  self : PiEventObserver,
  event : @posoco.TurnEvent,
) -> Unit {
  @posoco.Observer::on_event_at(self, None, event)
}

///|
/// Host-owned agent-run boundary: emits `agent_end` (messages accumulated
/// during the run) then `agent_settled`, matching pi's loop-drain semantics.
/// No-op when no run is active.
pub fn PiEventObserver::emit_agent_boundary(self : PiEventObserver) -> Unit {
  if !self.run_active {
    return
  }
  self.emit(
    "agent_end",
    Json::object(
      Map::from_array([("messages", Json::array(self.run_messages.copy()))]),
    ),
  )
  self.emit("agent_settled", Json::object(Map::from_array([])))
  self.run_active = false
  self.run_messages = []
}

///|
/// Clear run state on aborted host paths without further emits.
pub fn PiEventObserver::reset_agent_run(self : PiEventObserver) -> Unit {
  self.run_active = false
  self.run_messages = []
  self.reset_response()
}
