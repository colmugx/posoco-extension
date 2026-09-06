///|

///|
fn sanitize_tool_call_id(id : String) -> String {
  let buf = StringBuilder()
  for ch in id {
    if (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_' ||
      ch == '-' {
      buf.write_char(ch)
    } else {
      buf.write_char('_')
    }
  }
  let sanitized = buf.to_string()
  if sanitized.length() > 64 {
    sanitized.sub(end=64).to_owned()
  } else {
    sanitized
  }
}

///|
fn kimi_instructions_text(messages : Array[@posoco.Message]) -> String {
  let parts : Array[String] = []
  for message in messages {
    match message {
      SystemMessage(content~) => {
        let buf = StringBuilder()
        for block in content {
          match block {
            Text(text) => buf.write_string(text)
            Image(..) => ()
          }
        }
        let text = buf.to_string()
        if text.length() > 0 {
          parts.push(text)
        }
      }
      _ => ()
    }
  }
  parts.join("\n\n")
}

///|
fn kimi_sanitize_item_call_id(item : Json) -> Json {
  match item {
    Json::Object(map) => {
      let needs_sanitizing = match map.get("type") {
        Some(Json::String("function_call")) => true
        Some(Json::String("function_call_output")) => true
        _ => false
      }
      if needs_sanitizing {
        match map.get("call_id") {
          Some(Json::String(id)) =>
            map["call_id"] = Json::string(sanitize_tool_call_id(id))
          _ => ()
        }
      }
      item
    }
    other => other
  }
}

///|
fn kimi_input_items(messages : Array[@posoco.Message]) -> Array[Json] {
  let items : Array[Json] = []
  for message in messages {
    match message {
      SystemMessage(..) => ()
      msg =>
        for item in @responses.message_to_responses_items(msg) {
          items.push(kimi_sanitize_item_call_id(item))
        }
    }
  }
  items
}

///|
/// `reasoning_effort`: `Some("")` suppresses the `reasoning` field.
fn build_responses_request(
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  model : String,
  stream : Bool,
  cache_key : String?,
  reasoning_effort? : String? = None,
) -> Json {
  let fields : Array[(String, Json)] = [("model", Json::string(model))]
  let instructions = kimi_instructions_text(messages)
  if instructions.length() > 0 {
    fields.push(("instructions", Json::string(instructions)))
  }
  fields.push(("input", Json::array(kimi_input_items(messages))))
  let tool_entries : Array[Json] = tools.map(fn(t) {
    @responses.tool_to_responses_wire(t)
  })
  if !tool_entries.is_empty() {
    fields.push(("tools", Json::array(tool_entries)))
  }
  match reasoning_effort {
    Some(effort) =>
      if effort.length() > 0 {
        fields.push(
          ("reasoning", Json::object({ "effort": Json::string(effort) })),
        )
      }
    None => ()
  }
  match options.max_output_tokens {
    Some(n) => fields.push(("max_output_tokens", Json::number(n.to_double())))
    None => ()
  }
  match cache_key {
    Some(key) => fields.push(("prompt_cache_key", Json::string(key)))
    None => ()
  }
  if stream {
    fields.push(("stream", Json::boolean(true)))
  }
  // Deliberately absent: temperature/top_p/tool_choice (documented 400s on
  // the Kimi Responses wire), store/previous_response_id (stateless full
  // replay), search_context_size/blocked_domains (documented 400s),
  // max_completion_tokens/thinking/stream_options (chat-wire relics).
  Json::object(Map::from_array(fields))
}
