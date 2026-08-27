///|
/// Wire encoder: convert kernel canonical types to standard OpenAI
/// Chat Completions API JSON.
///
/// This is the plain OpenAI Chat Completions shape with the customary
/// reasoning surface: a selected effort level sends the top-level
/// `reasoning_effort` field verbatim, and enabling thinking without a level
/// sends the object form `thinking: {"type": "enabled"}`. A bare boolean is
/// never sent — strict gateways (OpenCode Zen's upstream) only accept the
/// object form. When thinking is off, both fields are omitted entirely so
/// the endpoint applies its own default. Tool call arguments are JSON
/// strings (OpenAI convention). Message order is append-only.

///|
/// Encode a kernel Message into an OpenAI chat message JSON object.
fn encode_message(msg : @posoco.Message, supports_images : Bool) -> Json {
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
  // Content encoding is shared across the chat-completions adapters: string
  // form by default (some compatible servers reject content arrays), typed
  // parts when images are present and the model accepts them, explicit
  // placeholder downgrade otherwise.
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
  // reasoning_content: fallback policy is keep-all (Kimi-style) — resend
  // whenever present. DeepSeek-style upstreams REQUIRE it on tool-call turns
  // and tolerate it elsewhere; plain endpoints never produce reasoning, so
  // nothing is ever sent to them.
  if role == "assistant" {
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
  thinking : Bool,
  reasoning_effort : String?,
  supports_images : Bool,
) -> Json {
  let body : Map[String, Json] = {
    "model": Json::string(model),
    "messages": Json::array(
      messages.map(fn(m) { encode_message(m, supports_images) }),
    ),
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
  // Thinking off omits the reasoning surface entirely — no `thinking`, no
  // `reasoning_effort`; the endpoint applies its own default. Thinking on
  // uses the object form (never a bare boolean, which strict gateways such
  // as OpenCode Zen's upstream reject); a selected level additionally sends
  // the top-level `reasoning_effort` verbatim.
  if thinking {
    body["thinking"] = Json::object({ "type": Json::string("enabled") })
    match reasoning_effort {
      Some(effort) => body["reasoning_effort"] = Json::string(effort)
      None => ()
    }
  }
  if stream {
    body["stream"] = Json::boolean(true)
    body["stream_options"] = Json::object({
      "include_usage": Json::boolean(true),
    })
  }
  Json::object(body)
}
