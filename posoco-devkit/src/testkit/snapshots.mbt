///|
/// Test support for Posoco extension authors: scripted and recording fakes.
///
/// Posoco 0.23.3 moved its conformance testkit into the module-internal
/// package `colmugx/posoco/internal/test_support`, which is not importable
/// from outside the module. This package carries the same testkit for
/// extension and host authors (semantics aligned with posoco 0.23.2, where
/// the same helpers were re-exported from the root package), plus the
/// deep-copy snapshot helpers that posoco keeps in its own internal packages
/// (`internal/message_snapshot`, `internal/event_snapshot`,
/// `internal/diagnostic`).
///
/// Scripted, recording fakes that let tests assert behavior contracts
/// (event order, metadata fidelity, tool-outcome consistency) rather than
/// implementation details: they record call order, arguments, and metadata
/// snapshots, and fail loudly when a script is exhausted.
///
/// Import this package only from `for "wbtest"` / `for "test"` sections of
/// `moon.pkg`, so production builds never link it.

///|
/// Deep-copy a JSON value so mutable Array/Map backing storage cannot cross a
/// message/metadata snapshot boundary.
pub fn snapshot_json(value : Json) -> Json {
  match value {
    Array(items) => Json::array(items.map(snapshot_json))
    Object(fields) => {
      let snapshot : Map[String, Json] = Map::from_array([])
      for key in fields.keys() {
        snapshot[key] = snapshot_json(fields[key])
      }
      Json::object(snapshot)
    }
    scalar => scalar
  }
}

///|
pub fn snapshot_tool_call(call : @kernel.ToolCall) -> @kernel.ToolCall {
  {
    call_id: call.call_id,
    name: call.name,
    arguments: snapshot_json(call.arguments),
  }
}

///|
pub fn snapshot_content(content : @kernel.Content) -> @kernel.Content {
  match content {
    Text(text) => Text(text)
    Image(media_type~, data~) => Image(media_type~, data~)
  }
}

///|
pub fn snapshot_tool_outcome(
  outcome : @kernel.ToolOutcome,
) -> @kernel.ToolOutcome {
  match outcome {
    Success(content~, structured~) =>
      Success(
        content~,
        structured=match structured {
          Some(j) => Some(snapshot_json(j))
          None => None
        },
      )
    SuccessWithAttachments(content~, structured~, attachments~) =>
      SuccessWithAttachments(
        content~,
        structured=match structured {
          Some(j) => Some(snapshot_json(j))
          None => None
        },
        attachments=attachments.copy(),
      )
    ToolReportedError(content~, structured~) =>
      ToolReportedError(
        content~,
        structured=match structured {
          Some(j) => Some(snapshot_json(j))
          None => None
        },
      )
    RuntimeFailure(error_category~, message~) =>
      RuntimeFailure(error_category~, message~)
    NotExecuted(reason~, original_call_id~) =>
      NotExecuted(reason~, original_call_id~)
  }
}

///|
pub fn snapshot_message(message : @kernel.Message) -> @kernel.Message {
  match message {
    SystemMessage(content~) =>
      SystemMessage(content=content.map(snapshot_content))
    UserMessage(content~) => UserMessage(content=content.map(snapshot_content))
    AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) =>
      AssistantMessage(
        content=content.map(snapshot_content),
        tool_calls=tool_calls.map(snapshot_tool_call),
        reasoning~,
        finish_reason~,
      )
    ToolMessage(call_id~, tool_name~, outcome~) =>
      ToolMessage(call_id~, tool_name~, outcome=snapshot_tool_outcome(outcome))
  }
}

///|
pub fn snapshot_messages(
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  messages.map(snapshot_message)
}

///|
pub fn snapshot_metadata(metadata : Map[String, Json]) -> Map[String, Json] {
  let snapshot : Map[String, Json] = Map::from_array([])
  for key in metadata.keys() {
    snapshot[key] = snapshot_json(metadata[key])
  }
  snapshot
}

///|
// ---- Event snapshots (mirrors colmugx/posoco/internal/event_snapshot) ----

///|

///|
fn snapshot_opt_json(value : Json?) -> Json? {
  match value {
    Some(j) => Some(snapshot_json(j))
    None => None
  }
}

///|
fn snapshot_tool_failure(failure : @kernel.ToolFailure) -> @kernel.ToolFailure {
  match failure {
    ReportedError(content~, structured~) =>
      ReportedError(content~, structured=snapshot_opt_json(structured))
    Runtime(category~, message~) => Runtime(category~, message~)
  }
}

///|
/// Deep-copy one observer event. Tool calls/messages use the shared message
/// snapshot layer; the payload-free and scalar-only variants pass through.
pub fn snapshot_turn_event(event : @types.TurnEvent) -> @types.TurnEvent {
  match event {
    TurnStarted => TurnStarted
    ModelRequestStarted => ModelRequestStarted
    ToolChildDeclared(..) => event
    ToolCatalogChanged(..) => event
    ToolCallPending(call) => ToolCallPending(snapshot_tool_call(call))
    ToolCallApproved(call~, consent_scope~) =>
      ToolCallApproved(call=snapshot_tool_call(call), consent_scope~)
    ToolCallStarted(call~) => ToolCallStarted(call=snapshot_tool_call(call))
    ToolCallSucceeded(call~, content~, structured~, attachments~) =>
      ToolCallSucceeded(
        call=snapshot_tool_call(call),
        content~,
        structured=snapshot_opt_json(structured),
        attachments=attachments.copy(),
      )
    ToolCallFailed(call~, failure~) =>
      ToolCallFailed(
        call=snapshot_tool_call(call),
        failure=snapshot_tool_failure(failure),
      )
    ToolCallRejected(call~, reason~) =>
      ToolCallRejected(call=snapshot_tool_call(call), reason~)
    ToolCallAbandoned(call~, reason~) =>
      ToolCallAbandoned(call=snapshot_tool_call(call), reason~)
    ModelResponseReceived(message~, usage~) =>
      ModelResponseReceived(message=snapshot_message(message), usage~)
    SessionRedirect(from~, to~, messages_before~, messages_after~) =>
      SessionRedirect(from~, to~, messages_before~, messages_after~)
    TurnCompleted => TurnCompleted
    TurnFailed(reason) => TurnFailed(reason)
    StreamChunkReceived(chunk~) => StreamChunkReceived(chunk~)
    StreamChunksDropped(count~) => StreamChunksDropped(count~)
    ConfigWarning(field~, value~, reason~) =>
      ConfigWarning(field~, value~, reason~)
    ConfigChanged(field~, old_value~, new_value~) =>
      ConfigChanged(field~, old_value~, new_value~)
    ContextStateUpdated(state~) => ContextStateUpdated(state~)
    CompactStarted(trigger~) => CompactStarted(trigger~)
    CompactFinished(trigger~, mode~, final_session_id~, messages_after~) =>
      CompactFinished(trigger~, mode~, final_session_id~, messages_after~)
    OperationFinalized(operation~, outcome~, detail~) =>
      OperationFinalized(operation~, outcome~, detail~)
    Custom(source~, label~, data~) =>
      Custom(source~, label~, data=snapshot_json(data))
    UserRequestStarted(kind~, prompt~) =>
      UserRequestStarted(kind~, prompt=safe_error_label(prompt))
    UserRequestFinished(kind~, outcome~) => UserRequestFinished(kind~, outcome~)
  }
}

///|
// ---- Bounded labels (mirrors colmugx/posoco/internal/diagnostic) ----

///|
pub fn bounded_error_label(value : String, cap : Int32) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in value {
    if chars.length() >= cap {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "...(truncated)"
  } else {
    label
  }
}

///|
pub fn safe_error_label(value : String) -> String {
  bounded_error_label(value, 64)
}
