///|
fn board_wire_scope(scope : @posoco.EventScope?) -> @protocol.BoardEventScope? {
  match scope {
    Some(value) =>
      Some({
        session_id: Some(value.session_id.to_string()),
        run_id: Some(value.run_id.to_string()),
        turn_id: Some(value.turn_id.to_string()),
      })
    None => None
  }
}

///|
fn board_redacted_line(line : String) -> String {
  let lower = line.to_lower()
  if lower.contains("authorization") ||
    lower.contains("api_key") ||
    lower.contains("apikey") ||
    lower.contains("access_token") ||
    lower.contains("refresh_token") ||
    lower.contains("password") ||
    lower.contains("secret") {
    "[redacted]"
  } else {
    line
  }
}

///|
/// Bound model/tool-facing text before it becomes browser-visible. The
/// redaction is intentionally conservative: suspicious credential-bearing
/// lines are replaced wholesale, then the display excerpt is capped.
fn board_safe_preview(text : String, limit? : Int = 2048) -> String {
  let lines : Array[String] = []
  for line in text.split("\n") {
    lines.push(board_redacted_line(line.to_owned()))
  }
  let clean = lines.join("\n")
  if clean.length() > limit {
    clean.exact_view(start=0, end=limit).to_owned() + "…[truncated]"
  } else {
    clean
  }
}

///|
fn BoardExtension::emit_wire_event(
  self : BoardExtension,
  scope : @posoco.EventScope?,
  kind : String,
  payload : Json,
) -> Unit {
  let _ = self.runtime_.publish_telemetry(
    board_revision=0L,
    kind~,
    scope=board_wire_scope(scope),
    payload~,
  )
}

///|
/// Synchronous Observer projection. No await, no socket access: this path only
/// appends to EventHub history and non-blocking per-client queues.
pub impl @posoco.Observer for BoardExtension with fn on_event_at(
  self : BoardExtension,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted =>
      self.emit_wire_event(scope, "run.started", Json::object({}))
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) =>
          self.emit_wire_event(
            scope,
            "assistant.delta",
            Json::object({ "text": Json::string(board_safe_preview(token, limit=4096)) }),
          )
        @posoco.StreamChunk::ReasoningDelta(token~) =>
          self.emit_wire_event(
            scope,
            "assistant.reasoning_delta",
            Json::object({ "text": Json::string(board_safe_preview(token, limit=4096)) }),
          )
        _ => ()
      }
    @posoco.TurnEvent::ToolCallPending(call) =>
      self.emit_wire_event(
        scope,
        "tool.pending",
        Json::object({
          "call_id": Json::string(call.call_id.to_string()),
          "tool": Json::string(call.name.to_string()),
        }),
      )
    @posoco.TurnEvent::ToolCallSucceeded(call~, content~, ..) =>
      self.emit_wire_event(
        scope,
        "tool.completed",
        Json::object({
          "call_id": Json::string(call.call_id.to_string()),
          "tool": Json::string(call.name.to_string()),
          "preview": Json::string(board_safe_preview(content)),
        }),
      )
    @posoco.TurnEvent::ToolCallFailed(call~, ..) =>
      self.emit_wire_event(
        scope,
        "tool.failed",
        Json::object({
          "call_id": Json::string(call.call_id.to_string()),
          "tool": Json::string(call.name.to_string()),
          "message": Json::string("tool execution failed"),
        }),
      )
    @posoco.TurnEvent::ToolCallRejected(call~, ..) =>
      self.emit_wire_event(
        scope,
        "tool.failed",
        Json::object({
          "call_id": Json::string(call.call_id.to_string()),
          "tool": Json::string(call.name.to_string()),
          "message": Json::string("tool call rejected"),
        }),
      )
    @posoco.TurnEvent::ToolCallAbandoned(call~, ..) =>
      self.emit_wire_event(
        scope,
        "tool.failed",
        Json::object({
          "call_id": Json::string(call.call_id.to_string()),
          "tool": Json::string(call.name.to_string()),
          "message": Json::string("tool call abandoned"),
        }),
      )
    @posoco.TurnEvent::ModelResponseReceived(usage~, ..) => {
      let payload = match usage {
        Some(value) =>
          Json::object({
            "input_tokens": match value.input_tokens {
              Some(n) => Json::number(n.to_double())
              None => Json::null()
            },
            "output_tokens": match value.output_tokens {
              Some(n) => Json::number(n.to_double())
              None => Json::null()
            },
            "total_tokens": match value.total_tokens {
              Some(n) => Json::number(n.to_double())
              None => Json::null()
            },
          })
        None => Json::object({})
      }
      self.emit_wire_event(scope, "model.response", payload)
    }
    @posoco.TurnEvent::UserRequestStarted(kind~, ..) =>
      self.emit_wire_event(
        scope,
        "run.blocked",
        Json::object({ "kind": Json::string(kind) }),
      )
    @posoco.TurnEvent::UserRequestFinished(kind~, outcome~) =>
      self.emit_wire_event(
        scope,
        "run.resumed",
        Json::object({
          "kind": Json::string(kind),
          "outcome": Json::string(outcome),
        }),
      )
    @posoco.TurnEvent::TurnCompleted =>
      self.emit_wire_event(scope, "run.completed", Json::object({}))
    @posoco.TurnEvent::TurnFailed(_) =>
      self.emit_wire_event(
        scope,
        "run.failed",
        Json::object({ "message": Json::string("turn failed") }),
      )
    @posoco.TurnEvent::StreamChunksDropped(count~) =>
      self.emit_wire_event(
        scope,
        "runtime.warning",
        Json::object({
          "code": Json::string("stream_chunks_dropped"),
          "count": Json::number(count.to_double()),
        }),
      )
    @posoco.TurnEvent::ConfigWarning(field~, ..) =>
      self.emit_wire_event(
        scope,
        "runtime.warning",
        Json::object({
          "code": Json::string("config_warning"),
          "field": Json::string(board_safe_preview(field, limit=128)),
        }),
      )
    _ => ()
  }
}

///|
/// Post-effect telemetry supplements the Observer channel only for adapter
/// failures. Successful model/tool terminal facts already arrive through
/// TurnEvent and are not duplicated here.
pub impl @posoco.PipelineHook for BoardExtension with fn on_post_event_at(
  self : BoardExtension,
  scope : @posoco.EventScope?,
  stage : @posoco.HookStage,
) -> Unit {
  match stage {
    @posoco.HookStage::ModelFailed(..) =>
      self.emit_wire_event(
        scope,
        "runtime.warning",
        Json::object({ "code": Json::string("model_effect_failed") }),
      )
    @posoco.HookStage::ToolFailed(call~, ..) =>
      self.emit_wire_event(
        scope,
        "runtime.warning",
        Json::object({
          "code": Json::string("tool_effect_failed"),
          "call_id": Json::string(call.call_id.to_string()),
          "tool": Json::string(call.name.to_string()),
        }),
      )
    _ => ()
  }
}

///|
/// No coalescing buffer exists in S2: terminal Observer events are enqueued
/// synchronously in order, so there is nothing separate to flush at turn end.
pub impl @posoco.PipelineHook for BoardExtension with fn on_turn_end(_self) -> Unit {
  ()
}

///|
pub extend BoardExtension with @posoco.Observer::{on_event, on_event_at}

///|
pub extend BoardExtension with @posoco.PipelineHook::{
  before_model,
  before_tool,
  on_post_event,
  on_post_event_at,
  on_turn_begin,
  on_turn_end,
}
