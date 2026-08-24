///|
/// Wire encoder: convert kernel canonical types to the OpenRouter
/// Chat Completions API JSON.
///
/// This is the standard OpenAI shape plus OpenRouter's reasoning surface:
/// thinking on sends `"include_reasoning": true` so the response carries
/// `reasoning_details`, and a selected effort level additionally sends the
/// top-level `reasoning_effort` field verbatim. Thinking off omits both
/// fields entirely so the endpoint applies its own default. Assistant
/// messages replay reasoning with the `reasoning_details` array verbatim
/// (taken from `Reasoning.raw` — encrypted blocks must survive byte-exact and
/// unordered), falling back to the plain `reasoning` string field when no raw
/// payload exists. The DeepSeek-style key `reasoning_content` is never used.
/// Streaming sends `"stream": true` only — OpenRouter deprecated
/// `stream_options.include_usage`; usage rides the final chunk automatically.
/// Tool call arguments are JSON strings (OpenAI convention). Message order is
/// append-only.

///|
/// Encode a kernel Message into an OpenRouter chat message JSON object.
fn encode_message(msg : @posoco.Message) -> Json {
  let (role, content_blocks, tool_calls, tool_call_id, reasoning) = match msg {
    SystemMessage(content~) => ("system", content, [], None, None)
    UserMessage(content~) => ("user", content, [], None, None)
    AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) => {
      let _ = finish_reason
      ("assistant", content, tool_calls, None, reasoning)
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
  // OpenRouter accepts either a string or an array of content blocks.
  // Concatenate Text blocks into a single string for widest compatibility.
  let text_builder = StringBuilder::new()
  for block in content_blocks {
    match block {
      Text(s) => text_builder.write_string(s)
      Image(..) => () // chat completions: images not supported here
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
  // Reasoning replay: prefer the provider-defined `reasoning_details` payload
  // stored on Reasoning.raw — encrypted blocks are required verbatim for
  // chain-of-thought continuation on tool-call turns. Without a raw payload,
  // fall back to the plain `reasoning` string field (never DeepSeek's
  // `reasoning_content`). Plain-text endpoints never produce reasoning, so
  // nothing is ever sent to them.
  if role == "assistant" {
    match reasoning {
      Some(r) =>
        match r.raw {
          Some(raw_json) => obj["reasoning_details"] = raw_json
          None => obj["reasoning"] = Json::string(r.content)
        }
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
/// the caller prepends base_url. `config` supplies the model id and the
/// reasoning surface (thinking / reasoning_effort).
fn build_chat_request(
  config : OpenRouterConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : Bool,
) -> Json {
  let body : Map[String, Json] = {
    "model": Json::string(config.model),
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
  // Thinking off omits the reasoning surface entirely — no `include_reasoning`,
  // no `reasoning_effort`; the endpoint applies its own default. Thinking on
  // sends `"include_reasoning": true` so responses carry `reasoning_details`;
  // a selected level additionally sends the top-level `reasoning_effort`
  // verbatim.
  if config.thinking {
    body["include_reasoning"] = Json::boolean(true)
    match config.reasoning_effort {
      Some(effort) => body["reasoning_effort"] = Json::string(effort)
      None => ()
    }
  }
  if stream {
    // stream_options.include_usage is deprecated on OpenRouter: usage rides
    // the final chunk automatically.
    body["stream"] = Json::boolean(true)
  }
  Json::object(body)
}
