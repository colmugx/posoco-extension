///|
/// Wire encoder: convert posoco types to DeepSeek API JSON.
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
  // reasoning_content: DeepSeek requires it to be resent when the assistant
  // message has tool_calls (otherwise 400 error). When there are no tool_calls,
  // resending is optional and wasteful (pollutes prefix cache), so we skip it.
  // This is the official recommendation from DeepSeek thinking_mode docs.
  if msg.role is Assistant && msg.tool_calls.length() > 0 {
    match msg.reasoning_content {
      Some(r) => obj["reasoning_content"] = Json::string(r)
      None => ()
    }
  }
  // NOTE: for non-tool-call turns, reasoning_content is deliberately omitted
  // even if present — see DeepSeek thinking_mode guide.
  Json::object(obj)
}

///|
/// Encode posoco ToolDef array into DeepSeek tool definitions.
fn encode_tools(tools : Array[@posoco.ToolDef]) -> Json {
  Json::array(
    tools.map(fn(t) {
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
  ctx : @devkit.ExtContext,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  model : String,
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
    Some(NamedTool(name)) =>
      body["tool_choice"] = Json::object({
        "type": Json::string("function"),
        "function": Json::object({ "name": Json::string(name) }),
      })
    None => ()
  }
  let (thinking, effort) = resolve_deepseek_thinking(
    ctx,
    options.reasoning_effort,
  )
  body["thinking"] = thinking
  match effort {
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

///|
fn reasoning_effort_name(effort : @posoco.ReasoningEffort) -> String {
  match effort {
    Off => "off"
    Minimal => "minimal"
    Low => "low"
    Medium => "medium"
    High => "high"
    Maximum => "maximum"
  }
}

///|
fn enabled_thinking_json() -> Json {
  Json::object({ "type": Json::string("enabled") })
}

///|
fn disabled_thinking_json() -> Json {
  Json::object({ "type": Json::string("disabled") })
}

///|
fn resolve_deepseek_thinking(
  ctx : @devkit.ExtContext,
  effort : @posoco.ReasoningEffort?,
) -> (Json, String?) {
  match effort {
    None | Some(Off) => (disabled_thinking_json(), None)
    Some(High) => (enabled_thinking_json(), Some("high"))
    Some(Maximum) => (enabled_thinking_json(), Some("max"))
    Some(other) => {
      ctx.warn(
        source="posoco-ext-deepseek",
        code="deepseek.effort_fallback",
        message="值不存在已自动路由到high",
        data=Some(
          Json::object({
            "requested": Json::string(reasoning_effort_name(other)),
            "routed_to": Json::string("high"),
          }),
        ),
      )
      (enabled_thinking_json(), Some("high"))
    }
  }
}
