///|
/// Wire encoder: convert kernel canonical types to DeepSeek API JSON.
///
/// DeepSeek-specific reasoning_content rules (per official thinking_mode guide):
/// - When the *current request* has tools, reasoning_content from every
///   assistant history turn MUST be replayed (even without tool_calls).
/// - When the current request has no tools, DeepSeek ignores historical
///   reasoning_content; omit it unless preserving legacy tool-call replay.
/// - Non-assistant messages: never carry reasoning_content.
/// - Tool call arguments are JSON strings (DeepSeek convention).
/// - Message order is append-only (prefix-cache friendly).

///|
/// Encode a kernel Message into a DeepSeek chat message JSON object.
/// FIM/prefix endpoints are text-only, so images keep the placeholder
/// downgrade here.
fn encode_message(msg : @posoco.Message) -> Json {
  encode_message_with_reasoning(msg, false, false)
}

///|
/// Request-aware encoding: DeepSeek requires full reasoning replay whenever
/// the outgoing request carries tools, even for plain assistant replies.
/// `supports_images` switches image blocks from the placeholder downgrade to
/// typed `image_url` content parts.
fn encode_message_with_reasoning(
  msg : @posoco.Message,
  replay_all_reasoning : Bool,
  supports_images : Bool,
) -> Json {
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
  // Shared content encoding: string form by default; when the configured
  // model accepts image input, image blocks encode as typed parts instead of
  // the explicit placeholder downgrade (never a silent drop).
  let content_json : Json = match
    @chatkit.encode_chat_message_content(content_blocks, supports_images~) {
    TextContent(s) => Json::string(s)
    PartsContent(parts) => Json::array(parts)
  }
  let obj : Map[String, Json] = {
    "role": Json::string(role),
    "content": content_json,
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
  if role == "assistant" && (replay_all_reasoning || tool_calls.length() > 0) {
    match reasoning_text {
      Some(r) => obj["reasoning_content"] = Json::string(r)
      None => ()
    }
  }
  // With tools enabled, previous assistant reasoning is replayed regardless
  // of whether that particular message contains a tool call.
  Json::object(obj)
}

///|
/// Flatten a ToolOutcome to the wire text DeepSeek expects in a tool-role
/// message's `content` field. Business errors surface their message;
/// runtime failures surface their category+message.
fn outcome_to_wire_text(outcome : @posoco.ToolOutcome) -> String {
  @chatkit.outcome_wire_text(outcome)
}

///|
/// Encode kernel ToolDef array into DeepSeek tool definitions.
fn encode_tools(tools : Array[@posoco.ToolDef]) -> Json {
  // OpenAI function tools are looked up by name, not declaration index.
  // Canonicalize the *wire* order only: host execution and registrations are
  // unchanged. Equal tool sets then share the V4.1 system prompt prefix.
  let ordered = tools.copy()
  ordered.sort_by((a, b) => {
    let by_name = a.name.to_string().compare(b.name.to_string())
    if by_name != 0 {
      by_name
    } else {
      let by_description = a.description.compare(b.description)
      if by_description != 0 {
        by_description
      } else {
        a.input_schema.stringify().compare(b.input_schema.stringify())
      }
    }
  })
  Json::array(
    ordered.map(fn(t) {
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
  supports_images : Bool,
) -> Json {
  let wire_messages = @chatkit.fold_tool_attachments(messages, supports_images).map(fn(
      message,
    ) {
      encode_message_with_reasoning(
        message,
        tools.length() > 0,
        supports_images,
      )
    },
  )
  if tools.length() > 0 && deepseek_repeated_tool_calls(messages) {
    wire_messages.push(
      Json::object({
        "role": Json::string("system"),
        "content": Json::string(deepseek_convergence_instruction()),
      }),
    )
  }
  let body : Map[String, Json] = {
    "model": Json::string(model),
    "messages": Json::array(wire_messages),
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
