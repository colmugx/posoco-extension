///|
/// Wire encoder: kernel canonical types to z.ai chat-completions JSON.
///
/// z.ai GLM specifics beyond plain OpenAI chat completions:
/// - `thinking: {"type": "enabled"|"disabled"}` switches GLM thinking;
/// - `reasoning_effort` rides along for GLM-5.2+ ("" disables thinking);
/// - `reasoning_content` on assistant messages MUST be resent when the
///   message carries tool_calls (same contract as DeepSeek; GLM 400s
///   otherwise). Without tool_calls it is omitted to save tokens.
/// - Message order is append-only (prefix-cache friendly).

///|
fn encode_message(msg : @posoco.Message) -> Json {
  let (role, content_blocks, tool_calls, tool_call_id, reasoning_text) = match
    msg {
    SystemMessage(content~) => ("system", content, [], None, None)
    UserMessage(content~) => ("user", content, [], None, None)
    AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) => {
      let _ = finish_reason
      let reasoning_str = match reasoning {
        Some(r) => Some(r.content)
        None => None
      }
      ("assistant", content, tool_calls, None, reasoning_str)
    }
    ToolMessage(call_id~, tool_name~, outcome~) => {
      let outcome_text = outcome_to_wire_text(outcome)
      let tool_blocks : Array[@posoco.Content] = [
        @posoco.Content::Text(outcome_text),
      ]
      let _ = tool_name
      ("tool", tool_blocks, [], Some(call_id.to_string()), None)
    }
  }
  let text_builder = StringBuilder::new()
  for block in content_blocks {
    match block {
      Text(s) => text_builder.write_string(s)
      Image(..) => () // GLM coding-plan chat does not accept images
    }
  }
  let content_str = text_builder.to_string()
  let obj : Map[String, Json] = {
    "role": Json::string(role),
    "content": Json::string(content_str),
  }
  match tool_call_id {
    Some(id) => obj["tool_call_id"] = Json::string(id)
    None => ()
  }
  if tool_calls.length() > 0 {
    let tc_arr = tool_calls.map(fn(tc) {
      Json::object({
        "id": Json::string(tc.call_id.to_string()),
        "type": Json::string("function"),
        "function": Json::object({
          "name": Json::string(tc.name.to_string()),
          "arguments": Json::string(tc.arguments.stringify()),
        }),
      })
    })
    obj["tool_calls"] = Json::array(tc_arr)
  }
  if role == "assistant" && tool_calls.length() > 0 {
    match reasoning_text {
      Some(r) => obj["reasoning_content"] = Json::string(r)
      None => ()
    }
  }
  Json::object(obj)
}

///|
fn outcome_to_wire_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(reason~, ..) => reason.to_string()
  }
}

///|
fn encode_tools(tools : Array[@posoco.ToolDef]) -> Json {
  Json::array(
    tools.map(fn(t) {
      Json::object({
        "type": Json::string("function"),
        "function": Json::object({
          "name": Json::string(t.name.to_string()),
          "description": Json::string(t.description),
          "parameters": t.input_schema,
        }),
      })
    }),
  )
}

///|
fn build_chat_request(
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  model : String,
  stream : Bool,
  thinking_enabled : Bool,
  reasoning_effort_str : String?,
) -> Json {
  let body : Map[String, Json] = {
    "model": Json::string(model),
    "messages": Json::array(messages.map(encode_message)),
  }
  if tools.length() > 0 {
    body["tools"] = encode_tools(tools)
  }
  match options.temperature {
    Some(t) => body["temperature"] = Json::number(t)
    None => ()
  }
  match options.max_output_tokens {
    Some(n) => body["max_tokens"] = Json::number(n.to_double())
    None => ()
  }
  body["thinking"] = if thinking_enabled {
    Json::object({ "type": Json::string("enabled") })
  } else {
    Json::object({ "type": Json::string("disabled") })
  }
  match reasoning_effort_str {
    Some(e) => body["reasoning_effort"] = Json::string(e)
    None => ()
  }
  if stream {
    body["stream"] = Json::boolean(true)
    body["stream_options"] = Json::object({
      "include_usage": Json::boolean(true),
    })
  }
  Json::object(body)
}
