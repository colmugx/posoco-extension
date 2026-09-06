///|
pub(all) struct ZcodeUsage {
  input_tokens : Int
  output_tokens : Int
  total_tokens : Int
} derive(Eq, Debug)

///|
/// The session/event subset we care about; everything else reduces to None
/// (noise: state.updated, v4/telemetry/event, process/mcpTelemetry,
/// computer-use/operation-event, and every unknown params.type).
pub(all) enum ZcodeEvent {
  TurnStarted
  TextDelta(String) // model.streaming kind=text_delta
  ReasoningDelta(String) // model.streaming kind=reasoning_delta
  ToolUpdated(tool_name~ : String, status~ : String) // tool.updated
  UsageSample(ZcodeUsage) // session.updated usage
  TitleUpdated(String) // session.titleUpdated
  TurnCompleted(response~ : String, usage~ : ZcodeUsage?) // terminal
  TurnFailed(message~ : String) // terminal
}

///|
/// Reduce one notification payload to an event. Only method "session/event"
/// produces events; within it params.type selects the payload shape. Unknown
/// methods/types and payloads missing required fields → None. TextDelta is
/// the fallback source for TurnCompleted.response when the server omits it
/// (the task loop keeps the buffer). The first parameter is
/// named `method_name` because `method` is a reserved word in the toolchain.
pub fn zcode_reduce_notification(
  method_name : String,
  params : Json,
) -> ZcodeEvent? {
  if method_name != "session/event" {
    return None
  }
  match json_field_string(params, "type") {
    Some("turn.started") => Some(TurnStarted)
    Some("model.streaming") =>
      match
        (json_field_string(params, "kind"), json_field_string(params, "delta")) {
        (Some("text_delta"), Some(delta)) => Some(TextDelta(delta))
        (Some("reasoning_delta"), Some(delta)) => Some(ReasoningDelta(delta))
        _ => None
      }
    Some("tool.updated") =>
      match
        (
          json_field_string(params, "toolName"),
          json_field_string(params, "kind"),
        ) {
        (Some(tool_name), Some(status)) =>
          Some(ToolUpdated(tool_name~, status~))
        _ => None
      }
    Some("session.updated") =>
      match json_field(params, "usage") {
        Some(usage) => Some(UsageSample(zcode_usage_of(usage)))
        None => None
      }
    Some("session.titleUpdated") =>
      match json_field_string(params, "title") {
        Some(title) => Some(TitleUpdated(title))
        None => None
      }
    Some("turn.completed") => {
      let usage = match json_field(params, "usage") {
        Some(u) => Some(zcode_usage_of(u))
        None => None
      }
      Some(
        TurnCompleted(
          response=json_field_string(params, "response").unwrap_or(""),
          usage~,
        ),
      )
    }
    Some("turn.failed") => {
      let message = match json_field(params, "error") {
        Some(error) => json_field_string(error, "message").unwrap_or("")
        None => ""
      }
      Some(TurnFailed(message~))
    }
    _ => None
  }
}

///|
/// Missing or non-numeric usage fields read as 0; token accounting tolerates
/// partial numbers (provider extras like cacheReadTokens are ignored).
fn zcode_usage_of(usage : Json) -> ZcodeUsage {
  {
    input_tokens: json_field_int(usage, "inputTokens"),
    output_tokens: json_field_int(usage, "outputTokens"),
    total_tokens: json_field_int(usage, "totalTokens"),
  }
}
