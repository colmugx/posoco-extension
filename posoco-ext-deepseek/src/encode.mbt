///|
/// Wire encoder: convert kernel canonical types to DeepSeek API JSON.
///
/// DeepSeek-specific reasoning_content rules (per official thinking_mode guide):
/// - Assistant message WITH tool_calls: reasoning_content MUST be resent in
///   all subsequent turns (otherwise DeepSeek returns 400).
/// - Assistant message WITHOUT tool_calls: reasoning_content is optional;
///   omitting it saves tokens and preserves prefix cache.
/// - Non-assistant messages: never carry reasoning_content.
/// - Tool call arguments are JSON strings (DeepSeek convention).
/// - Message order is append-only (prefix-cache friendly).

///|
/// Encode a kernel Message into a DeepSeek chat message JSON object.
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
      // Tool messages carry the outcome content as the wire "content", plus
      // the `tool_call_id` of the assistant tool_call they answer — the
      // mandatory correlation key (OpenAI-compatible convention).
      let outcome_text = outcome_to_wire_text(outcome)
      let tool_blocks : Array[@posoco.Content] = [
        @posoco.Content::Text(outcome_text),
      ]
      let _ = tool_name
      ("tool", tool_blocks, [], Some(call_id.to_string()), None)
    }
  }
  // Concatenate Text content blocks into a single string (DeepSeek does not
  // support content arrays, only a string field).
  let text_builder = StringBuilder::new()
  for block in content_blocks {
    match block {
      Text(s) => text_builder.write_string(s)
      Image(..) => () // DeepSeek chat does not support images
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
  // Tool calls (assistant messages requesting tool execution)
  if tool_calls.length() > 0 {
    let tc_arr = tool_calls.map(fn(tc) {
      let tc_obj : Map[String, Json] = {
        "id": Json::string(tc.call_id.to_string()),
        "type": Json::string("function"),
        "function": Json::object({
          "name": Json::string(tc.name.to_string()),
          "arguments": Json::string(tc.arguments.stringify()),
        }),
      }
      Json::object(tc_obj)
    })
    obj["tool_calls"] = Json::array(tc_arr)
  }
  // reasoning_content: DeepSeek requires it to be resent when the assistant
  // message has tool_calls (otherwise 400 error). When there are no tool_calls,
  // resending is optional and wasteful (pollutes prefix cache), so we skip it.
  // This is the official recommendation from DeepSeek thinking_mode docs.
  if role == "assistant" && tool_calls.length() > 0 {
    match reasoning_text {
      Some(r) => obj["reasoning_content"] = Json::string(r)
      None => ()
    }
  }
  // NOTE: for non-tool-call turns, reasoning_content is deliberately omitted
  // even if present — see DeepSeek thinking_mode guide.
  Json::object(obj)
}

///|
/// Flatten a ToolOutcome to the wire text DeepSeek expects in a tool-role
/// message's `content` field. Business errors surface their message;
/// runtime failures surface their category+message.
fn outcome_to_wire_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(reason~, ..) => reason.to_string()
  }
}

///|
/// Encode kernel ToolDef array into DeepSeek tool definitions.
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
/// Build the full chat completions request body.
/// `base_url` is prepended by the caller; this returns just the JSON payload.
fn build_chat_request(
  ctx : @devkit.ExtContext,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  model : String,
  stream : Bool,
  thinking_json : Json,
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
  body["thinking"] = thinking_json
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
  let _ = ctx
  Json::object(body)
}

///|
fn enabled_thinking_json() -> Json {
  Json::object({ "type": Json::string("enabled") })
}
