///|
/// Wire encoder: convert kernel canonical types to standard OpenAI
/// Chat Completions API JSON.
///
/// This is the plain OpenAI Chat Completions shape — no DeepSeek-specific
/// `reasoning_content` resending rule, no `thinking` wrapper. Servers that
/// support reasoning expose it via the optional top-level `reasoning_effort`
/// field (set on the request body, not per-message). Tool call arguments are
/// JSON strings (OpenAI convention). Message order is append-only.

///|
/// Encode a kernel Message into an OpenAI chat message JSON object.
fn encode_message(msg : @posoco.Message) -> Json {
  let (role, content_blocks, tool_calls) = match msg {
    SystemMessage(content~) => ("system", content, [])
    UserMessage(content~) => ("user", content, [])
    AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) => {
      let _ = reasoning
      let _ = finish_reason
      ("assistant", content, tool_calls)
    }
    ToolMessage(call_id~, tool_name~, outcome~) => {
      // Standard OpenAI tool role: the outcome content carries back to the
      // model. `call_id` and `tool_name` are not encoded here because the
      // plain `tool` role relies on server-side correlation via message order;
      // servers that require explicit `tool_call_id` are handled by the host
      // adapter layer.
      let _ = call_id
      let _ = tool_name
      let outcome_text = outcome_to_wire_text(outcome)
      let tool_blocks : Array[@posoco.Content] = [
        @posoco.Content::Text(outcome_text),
      ]
      ("tool", tool_blocks, [])
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
