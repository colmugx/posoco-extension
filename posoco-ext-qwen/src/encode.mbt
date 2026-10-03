///|
fn encode_message(
  msg : @posoco.Message,
  supports_images : Bool,
  preserve_thinking : Bool,
) -> Json {
  let (role, content_blocks, tool_calls, tool_call_id, reasoning_text) = match
    msg {
    SystemMessage(content~) => ("system", content, [], None, None)
    UserMessage(content~) => ("user", content, [], None, None)
    AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) => {
      let _ = finish_reason
      let reasoning_text = match reasoning {
        Some(value) => Some(value.content)
        None => None
      }
      ("assistant", content, tool_calls, None, reasoning_text)
    }
    ToolMessage(call_id~, tool_name~, outcome~) => {
      let _ = tool_name
      let blocks : Array[@posoco.Content] = [
        @posoco.Content::Text(@chatkit.outcome_wire_text(outcome)),
      ]
      ("tool", blocks, [], Some(call_id.to_string()), None)
    }
  }
  let content_json : Json = match
    @chatkit.encode_chat_message_content(content_blocks, supports_images~) {
    TextContent(value) => Json::string(value)
    PartsContent(parts) => Json::array(parts)
  }
  let obj : Map[String, Json] = {
    "role": Json::string(role),
    "content": content_json,
  }
  match tool_call_id {
    Some(value) => obj["tool_call_id"] = Json::string(value)
    None => ()
  }
  if tool_calls.length() > 0 {
    obj["tool_calls"] = Json::array(
      tool_calls.map(fn(call) {
        Json::object({
          "id": Json::string(call.call_id.to_string()),
          "type": Json::string("function"),
          "function": Json::object({
            "name": Json::string(call.name.to_string()),
            "arguments": Json::string(call.arguments.stringify()),
          }),
        })
      }),
    )
  }
  if role == "assistant" && preserve_thinking {
    match reasoning_text {
      Some(value) =>
        if value.length() > 0 {
          obj["reasoning_content"] = Json::string(value)
        }
      None => ()
    }
  }
  Json::object(obj)
}

///|
fn encode_tools(tools : Array[@posoco.ToolDef]) -> Json {
  Json::array(
    tools.map(fn(tool) {
      Json::object({
        "type": Json::string("function"),
        "function": Json::object({
          "name": Json::string(tool.name.to_string()),
          "description": Json::string(tool.description),
          "parameters": tool.input_schema,
        }),
      })
    }),
  )
}

///|
fn build_chat_request(
  config : QwenConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : Bool,
) -> Json {
  let folded = @chatkit.fold_tool_attachments(messages, config.supports_images)
  let body : Map[String, Json] = {
    "model": Json::string(config.model),
    "messages": Json::array(
      folded.map(fn(message) {
        encode_message(
          message,
          config.supports_images,
          config.preserve_thinking,
        )
      }),
    ),
  }
  if tools.length() > 0 {
    body["tools"] = encode_tools(tools)
  }
  match options.temperature {
    Some(value) => body["temperature"] = Json::number(value)
    None => ()
  }
  match options.max_output_tokens {
    Some(value) => body["max_tokens"] = Json::number(value.to_double())
    None => ()
  }
  match config.reasoning_effort {
    Some(value) => body["reasoning_effort"] = Json::string(value)
    None => ()
  }
  match config.enable_thinking {
    Some(value) => body["enable_thinking"] = Json::boolean(value)
    None => ()
  }
  if config.emit_preserve_thinking {
    body["preserve_thinking"] = Json::boolean(config.preserve_thinking)
  }
  if stream {
    body["stream"] = Json::boolean(true)
    body["stream_options"] = Json::object({
      "include_usage": Json::boolean(true),
    })
    if config.tool_stream {
      body["tool_stream"] = Json::boolean(true)
    }
  }
  Json::object(body)
}
