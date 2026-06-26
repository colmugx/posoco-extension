///|
/// Wire encoder: convert posoco types to DeepSeek API JSON.
///
/// DeepSeek-specific correctness:
/// - Historical assistant messages NEVER carry `reasoning_content` (it is a
///   one-shot field from deepseek-reasoner; resending it wastes ~11% tokens
///   and pollutes the prefix cache). posoco's Message type has no reasoning
///   field, so this is structurally guaranteed.
/// - Tool call arguments are JSON strings (DeepSeek convention).
/// - Message order is append-only (prefix-cache friendly).

///|
/// Encode a posoco Message into a DeepSeek chat message JSON object.
fn encode_message(msg : @posoco.Message) -> Json {
  let role = match msg.role {
    System => "system"
    User => "user"
    Assistant => "assistant"
    Tool => "tool"
  }
  // Concatenate Text content blocks into a single string (DeepSeek does not
  // support content arrays, only a string field).
  let text_builder = StringBuilder::new()
  for block in msg.content {
    match block {
      Text(s) => text_builder.write_string(s)
      Image(_, _) => () // DeepSeek chat does not support images
    }
  }
  let content_str = text_builder.to_string()
  let obj : Map[String, Json] = {
    "role": Json::string(role),
    "content": Json::string(content_str),
  }
  // Tool calls (assistant messages requesting tool execution)
  if msg.tool_calls.length() > 0 {
    let tc_arr = msg.tool_calls.map(fn(tc) {
      let tc_obj : Map[String, Json] = {
        "id": Json::string(tc.id),
        "type": Json::string("function"),
        "function": Json::object({
          "name": Json::string(tc.name),
          "arguments": Json::string(tc.arguments.stringify()),
        }),
      }
      Json::object(tc_obj)
    })
    obj["tool_calls"] = Json::array(tc_arr)
  }
  // Tool result id (for tool-role messages)
  match msg.tool_call_id {
    Some(id) => obj["tool_call_id"] = Json::string(id)
    None => ()
  }
  match msg.name {
    Some(n) => obj["name"] = Json::string(n)
    None => ()
  }
  // NOTE: deliberately no `reasoning_content` — see module doc.
  Json::object(obj)
}

///|
/// Encode posoco ToolDef array into DeepSeek tool definitions.
fn encode_tools(tools : Array[@posoco.ToolDef]) -> Json {
  Json::array(
    tools
      .map(fn(t) {
        Json::object({
          "type": Json::string("function"),
          "function": Json::object({
            "name": Json::string(t.name),
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
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  model : String,
  thinking : ThinkingMode,
  stream : Bool,
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
  match options.tool_choice {
    Some(Auto) => body["tool_choice"] = Json::string("auto")
    Some(NoTool) => body["tool_choice"] = Json::string("none")
    Some(Required) => body["tool_choice"] = Json::string("required")
    Some(NamedTool(_)) => () // DeepSeek may not support named tool choice
    None => ()
  }
  // DeepSeek thinking effort (reasoner model only)
  match thinking {
    No => ()
    High => body["thinking"] = Json::object({ "effort": Json::string("high") })
    Max => body["thinking"] = Json::object({ "effort": Json::string("max") })
  }
  if stream {
    body["stream"] = Json::boolean(true)
    body["stream_options"] = Json::object({ "include_usage": Json::boolean(true) })
  }
  Json::object(body)
}
