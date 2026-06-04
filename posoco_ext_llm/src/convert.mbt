///|
/// convert.mbt — Message and tool conversion between posoco and OpenAI formats.
///
/// Shared by chat() and chat_streaming() implementations.

///|
/// Convert a posoco Message to an OpenAI Responses API input item (Json).
pub fn posoco_message_to_openai(msg : @posoco.Message) -> Json {
  match msg.role {
    @posoco.Role::User => Json::object(
      Map::from_array([
        ("role", Json::string("user")),
        (
          "content",
          Json::array(msg.content.map(fn(c) { content_to_openai(c) })),
        ),
      ]),
    )
    @posoco.Role::Assistant => {
      let content_arr = msg.content.map(fn(c) { content_to_openai(c) })
      let fields : Array[(String, Json)] = [
        ("role", Json::string("assistant")),
      ]
      if !content_arr.is_empty() {
        fields.push(("content", Json::array(content_arr)))
      }
      Json::object(Map::from_array(fields))
    }
    @posoco.Role::Tool => {
      let text = match msg.content {
        [@posoco.Content::Text(t), ..] => t
        _ => ""
      }
      let call_id = match msg.tool_call_id {
        Some(id) => id
        None => ""
      }
      Json::object(
        Map::from_array([
          ("type", Json::string("function_call_output")),
          ("call_id", Json::string(call_id)),
          ("output", Json::string(text)),
        ]),
      )
    }
    @posoco.Role::System => Json::object(
      Map::from_array([
        ("role", Json::string("system")),
        (
          "content",
          Json::array(msg.content.map(fn(c) { content_to_openai(c) })),
        ),
      ]),
    )
  }
}

///|
/// Convert a posoco Content item to OpenAI input content format.
fn content_to_openai(c : @posoco.Content) -> Json {
  match c {
    @posoco.Content::Text(t) => Json::object(
      Map::from_array([
        ("type", Json::string("input_text")),
        ("text", Json::string(t)),
      ]),
    )
    @posoco.Content::Image(mime_type, data) => Json::object(
      Map::from_array([
        ("type", Json::string("input_image")),
        (
          "image_url",
          Json::string("data:\{mime_type};base64,\{data}"),
        ),
      ]),
    )
  }
}

///|
/// Convert a posoco ToolDef to an OpenAI function tool definition.
pub fn posoco_tool_to_openai(tool : @posoco.ToolDef) -> Json {
  let fields : Array[(String, Json)] = [
    ("type", Json::string("function")),
    ("name", Json::string(tool.name)),
    ("description", Json::string(tool.description)),
    ("parameters", tool.input_schema),
  ]
  Json::object(Map::from_array(fields))
}

///|
/// Extract tool calls from OpenAI Responses API output array.
fn extract_tool_calls(output : Json) -> (Array[@posoco.ToolCall], Bool) {
  let items = match output {
    Json::Array(arr) => arr
    _ => return ([], false)
  }
  let tool_calls : Array[@posoco.ToolCall] = []
  let mut has_fc = false
  for item in items {
    match item {
      Json::Object(map) =>
        match map.get("type") {
          Some(Json::String(t)) =>
            if t == "function_call" {
              has_fc = true
              let id = match map.get("call_id") {
                Some(Json::String(s)) => s
                _ =>
                  match map.get("id") {
                    Some(Json::String(s)) => s
                    _ => ""
                  }
              }
              let name = match map.get("name") {
                Some(Json::String(s)) => s
                _ => ""
              }
              let args_str = match map.get("arguments") {
                Some(Json::String(s)) => s
                _ => "{}"
              }
              let args : Json = @json.parse(args_str) catch {
                _ => Json::object(Map::from_array([]))
              }
              tool_calls.push(
                @posoco.ToolCall::{ id, name, arguments: args },
              )
            }
          _ => ()
        }
      _ => ()
    }
  }
  (tool_calls, has_fc)
}

///|
/// Extract assistant message content from OpenAI Responses API output array.
fn extract_assistant_content(output : Json) -> Array[@posoco.Content] {
  let items = match output {
    Json::Array(arr) => arr
    _ => return []
  }
  let content : Array[@posoco.Content] = []
  for item in items {
    match item {
      Json::Object(map) =>
        match map.get("type") {
          Some(Json::String(t)) =>
            if t == "message" {
              match map.get("content") {
                Some(Json::Array(content_items)) =>
                  for ci in content_items {
                    match ci {
                      Json::Object(ci_map) =>
                        match ci_map.get("type") {
                          Some(Json::String("output_text")) =>
                            match ci_map.get("text") {
                              Some(Json::String(s)) =>
                                content.push(@posoco.Content::Text(s))
                              _ => ()
                            }
                          _ => ()
                        }
                      _ => ()
                    }
                  }
                _ => ()
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  content
}

///|
/// Extract usage from OpenAI Responses API response.
fn extract_usage(resp : Json) -> @posoco.Usage? {
  match resp {
    Json::Object(map) =>
      match map.get("usage") {
        Some(Json::Object(usage_map)) => {
          let input_tokens = match usage_map.get("input_tokens") {
            Some(Json::Number(n, ..)) => Some(n.to_int())
            _ => None
          }
          let output_tokens = match usage_map.get("output_tokens") {
            Some(Json::Number(n, ..)) => Some(n.to_int())
            _ => None
          }
          let total = match (input_tokens, output_tokens) {
            (Some(i), Some(o)) => Some(i + o)
            _ => None
          }
          Some(
            @posoco.Usage::{
              input_tokens,
              output_tokens,
              total_tokens: total,
            },
          )
        }
        _ => None
      }
    _ => None
  }
}

///|
/// Determine FinishReason from OpenAI response status and tool calls.
fn extract_finish_reason(
  resp : Json,
  has_tool_calls : Bool,
) -> @posoco.FinishReason {
  if has_tool_calls {
    return @posoco.FinishReason::ToolCalls
  }
  match resp {
    Json::Object(map) =>
      match map.get("status") {
        Some(Json::String("completed")) => @posoco.FinishReason::Stop
        Some(Json::String("incomplete")) => @posoco.FinishReason::Length
        Some(Json::String(s)) => @posoco.FinishReason::Other(s)
        _ => @posoco.FinishReason::Stop
      }
    _ => @posoco.FinishReason::Stop
  }
}

///|
/// Parse a complete OpenAI Responses API response into a posoco ModelResponse.
pub fn parse_openai_response(resp_json : Json) -> @posoco.ModelResponse {
  let output = match resp_json {
    Json::Object(map) =>
      match map.get("output") {
        Some(o) => o
        None => Json::array([])
      }
    _ => Json::array([])
  }
  let (tool_calls, has_fc) = extract_tool_calls(output)
  let content = extract_assistant_content(output)
  let final_message : @posoco.Message = {
    role: @posoco.Role::Assistant,
    content: content,
    tool_calls: tool_calls,
    tool_call_id: None,
    name: None,
  }
  let usage = extract_usage(resp_json)
  let finish_reason = extract_finish_reason(resp_json, has_fc)
  @posoco.ModelResponse::{
    message: final_message,
    tool_calls: tool_calls,
    finish_reason: finish_reason,
    usage: usage,
    reasoning_summary: None,
  }
}
