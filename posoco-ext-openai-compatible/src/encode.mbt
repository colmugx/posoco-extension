///|
/// Wire encoder: convert kernel canonical types to standard OpenAI
/// Chat Completions API JSON.
///
/// This is the plain OpenAI Chat Completions shape — no `thinking` wrapper.
/// Servers that support reasoning expose it via the optional top-level
/// `reasoning_effort` field (set on the request body, not per-message).
/// Tool call arguments are JSON strings (OpenAI convention). Message order
/// is append-only.
///
/// Wire rules verified against opencode-zen (curl A/B/C, 2026-08):
/// - Tool-role messages MUST carry `tool_call_id` — the correlation key for
///   the assistant tool_call they answer. OpenAI requires it; zen's upstream
///   drops the request silently without it. There is no "host adapter layer"
///   that adds it later; it must be encoded here.
/// - Assistant messages WITH tool_calls resend `reasoning_content` when the
///   model produced reasoning: thinking-mode upstreams (DeepSeek behind zen)
///   400 without it ("The reasoning_content in the thinking mode must be
///   passed back to the API"). Assistant messages WITHOUT tool_calls omit it
///   (saves tokens, preserves prefix cache). Plain OpenAI models never
///   populate reasoning, so the field is only ever sent to endpoints that
///   require it.

///|
/// Encode a kernel Message into an OpenAI chat message JSON object.
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
      // The outcome content carries back to the model; `tool_call_id` is the
      // mandatory correlation key for the assistant tool_call it answers.
      let outcome_text = outcome_to_wire_text(outcome)
      let tool_blocks : Array[@posoco.Content] = [
        @posoco.Content::Text(outcome_text),
      ]
      let _ = tool_name
      ("tool", tool_blocks, [], Some(call_id.to_string()), None)
    }
  }
  // OpenAI Chat Completions accepts either a string or an array of content
  // blocks. Concatenate Text blocks into a single string for widest server
  // compatibility (some compatible servers reject content arrays).
  let text_builder = StringBuilder::new()
  for block in content_blocks {
    match block {
      Text(s) => text_builder.write_string(s)
      Image(..) => () // plain chat completions: images not supported here
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
  // reasoning_content: thinking-mode upstreams require it to be resent when
  // the assistant message has tool_calls (otherwise 400). Without tool_calls
  // it is optional and wasteful (pollutes prefix cache), so we skip it.
  if role == "assistant" && tool_calls.length() > 0 {
    match reasoning_text {
      Some(r) => obj["reasoning_content"] = Json::string(r)
      None => ()
    }
  }
  Json::object(obj)
}

///|
/// Flatten a ToolOutcome to the wire text the tool-role message carries in its
/// `content` field. Business errors surface their message; runtime failures
/// surface their category+message.
fn outcome_to_wire_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(reason~, ..) => reason.to_string()
  }
}

///|
/// Encode kernel ToolDef array into OpenAI tool definitions.
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
/// Build the full chat completions request body. Returns just the JSON payload;
/// the caller prepends base_url.
fn build_chat_request(
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  model : String,
  stream : Bool,
  reasoning_effort : String,
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
  if reasoning_effort.length() > 0 {
    body["reasoning_effort"] = Json::string(reasoning_effort)
  }
  if stream {
    body["stream"] = Json::boolean(true)
    body["stream_options"] = Json::object({
      "include_usage": Json::boolean(true),
    })
  }
  Json::object(body)
}
