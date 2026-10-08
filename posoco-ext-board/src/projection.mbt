///|
/// Reject inputs over 16384 UTF-16 units before any copying or scanning.
/// Within budget, strip unsafe controls, then redact entire credential-bearing
/// lines before the 1024-character display cap. This is not a DLP scanner.
fn board_display(text : String) -> String {
  // String::length is the constant-time UTF-16 length intrinsic on native/JS.
  if text.length() > 16384 {
    return "[truncated]"
  }
  let safe = String::from_array(
    text
    .to_array()
    .filter(ch => {
      let code = ch.to_int()
      !((code < 0x20 && code != 0x09 && code != 0x0A) ||
      (code >= 0x7F && code <= 0x9F) ||
      (code >= 0x202A && code <= 0x202E) ||
      (code >= 0x2066 && code <= 0x2069))
    }),
  )
  let lines : Array[String] = []
  for line in safe.split("\n") {
    let lower = line.to_owned().to_lower()
    let sensitive = [
      "authorization", "api_key", "apikey", "access_token", "refresh_token", "password",
      "secret",
    ].any(key => lower.contains(key))
    lines.push(if sensitive { "[redacted]" } else { line.to_owned() })
  }
  let chars = lines.join("\n").to_array()
  if chars.length() <= 1024 {
    String::from_array(chars)
  } else {
    String::from_array(chars[:1010].to_owned()) + "...[truncated]"
  }
}

///|
fn board_scope(scope : @posoco.EventScope?) -> @protocol.BoardEventScope? {
  scope.map(s => {
    session_id: Some(s.session_id.to_string()),
    run_id: Some(s.run_id.to_string()),
    turn_id: Some(s.turn_id.to_string()),
  })
}

///|
fn board_tool(call : @posoco.ToolCall, preview : String) -> Json {
  {
    "call_id": call.call_id.to_string(),
    "tool": board_display(call.name.to_string()),
    "preview": board_display(preview),
  }
}

///|
fn board_count(count : Int?) -> Json {
  match count {
    Some(value) => value.to_json()
    None => Json::null()
  }
}

///|
fn board_usage(usage : @posoco.Usage?) -> Json {
  match usage {
    None => Json::null()
    Some(u) =>
      {
        "input_tokens": board_count(u.input_tokens),
        "output_tokens": board_count(u.output_tokens),
        "total_tokens": board_count(u.total_tokens),
        "cached_input_tokens": board_count(u.cached_input_tokens),
        "uncached_input_tokens": board_count(u.uncached_input_tokens),
      }
  }
}

///|
/// Single allowlist: no arguments, structured results, attachments, raw model
/// messages or provider failures cross this boundary. Terminal error previews
/// are deliberately fixed labels rather than lossy copies of opaque errors.
fn board_projection(event : @posoco.TurnEvent) -> (String, Json)? {
  Some(
    match event {
      TurnStarted => ("run.started", {})
      TurnCompleted => ("run.completed", {})
      TurnFailed(_) => ("run.failed", { "preview": "Run failed" })
      StreamChunkReceived(chunk=TextDelta(token~)) =>
        ("assistant.delta", { "text": board_display(token) })
      StreamChunkReceived(chunk=ReasoningDelta(token~)) =>
        ("assistant.reasoning_delta", { "text": board_display(token) })
      ToolCallPending(call) => ("tool.pending", board_tool(call, "Pending"))
      ToolCallSucceeded(call~, content~, ..) =>
        ("tool.completed", board_tool(call, content))
      ToolCallFailed(call~, ..) => ("tool.failed", board_tool(call, "Failed"))
      ToolCallRejected(call~, ..) =>
        ("tool.failed", board_tool(call, "Rejected"))
      ToolCallAbandoned(call~, ..) =>
        ("tool.failed", board_tool(call, "Abandoned"))
      ModelResponseReceived(usage~, ..) =>
        ("model.response", { "usage": board_usage(usage) })
      UserRequestStarted(kind~, prompt~) =>
        (
          "run.blocked",
          { "kind": board_display(kind), "prompt": board_display(prompt) },
        )
      UserRequestFinished(kind~, outcome~) =>
        (
          "run.resumed",
          { "kind": board_display(kind), "outcome": board_display(outcome) },
        )
      StreamChunksDropped(count~) =>
        ("runtime.warning", { "code": "stream_chunks_dropped", "count": count })
      ConfigWarning(..) =>
        (
          "runtime.warning",
          {
            "code": "config_warning",
            "preview": "Configuration could not be applied",
          },
        )
      _ => return None
    },
  )
}

///|
pub impl @posoco.Observer for BoardExtension with fn on_event_at(
  self,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match board_projection(event) {
    Some((kind, payload)) => {
      let _ = self
        .backend()
        .publish_telemetry(
          board_revision=0L,
          kind~,
          scope=board_scope(scope),
          payload~,
        )
    }
    None => ()
  }
}

///|
pub impl @posoco.Observer for BoardExtension with fn on_event(self, event) -> Unit {
  self.on_event_at(None, event)
}

///|
pub extend BoardExtension with @posoco.Observer::{on_event, on_event_at}
