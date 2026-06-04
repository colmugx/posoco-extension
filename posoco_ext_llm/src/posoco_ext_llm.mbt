///|
/// posoco_ext_llm.mbt — OpenAI Responses API adapter for posoco.
///
/// Implements ModelPort::chat() and chat_streaming() using the Responses API.
/// chat_streaming uses SSE (Server-Sent Events) with StreamAccumulator.

///|
/// Configuration for the OpenAI Responses API adapter.
pub(all) struct OpenAIConfig {
  api_key : String
  model : String
  base_url : String         // default: "https://api.openai.com/v1"
  organization : String?
}

///|
/// Create an OpenAIConfig with defaults.
pub fn OpenAIConfig::new(
  api_key : String,
  model : String,
) -> OpenAIConfig {
  {
    api_key,
    model,
    base_url: "https://api.openai.com/v1".to_string(),
    organization: None,
  }
}

///|
/// OpenAI ModelPort adapter — implements posoco's ModelPort trait.
pub(all) struct OpenAIModelPort {
  config : OpenAIConfig
}

///|
pub fn OpenAIModelPort::new(config : OpenAIConfig) -> OpenAIModelPort {
  { config, }
}

///|
/// Build the HTTP headers for OpenAI API requests.
fn build_headers(config : OpenAIConfig) -> Map[String, String] {
  let headers : Map[String, String] = {
    "Authorization": "Bearer " + config.api_key,
    "Content-Type": "application/json",
  }
  match config.organization {
    Some(org) => headers.set("OpenAI-Organization", org)
    None => ()
  }
  headers
}

///|
/// Build the JSON request body for the Responses API.
fn build_request_body(
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  model : String,
  stream~ : Bool = false,
) -> Json {
  let input_items = messages.map(fn(m) {
    posoco_message_to_openai(m)
  })
  let fields : Array[(String, Json)] = [
    ("model", Json::string(model)),
    ("input", Json::array(input_items)),
  ]
  if stream {
    fields.push(("stream", Json::boolean(true)))
  }
  if !tools.is_empty() {
    let tool_defs = tools.map(fn(t) { posoco_tool_to_openai(t) })
    fields.push(("tools", Json::array(tool_defs)))
  }
  let final_fields = append_options(fields, options)
  Json::object(Map::from_array(final_fields))
}

///|
/// Append ChatOptions to request body fields.
fn append_options(
  fields : Array[(String, Json)],
  options : @posoco.ChatOptions,
) -> Array[(String, Json)] {
  let result : Array[(String, Json)] = []
  for f in fields {
    result.push(f)
  }
  match options.temperature {
    Some(t) => result.push(("temperature", Json::number(t)))
    None => ()
  }
  match options.max_output_tokens {
    Some(n) => result.push(("max_output_tokens", Json::number(n.to_double())))
    None => ()
  }
  result
}

// ——— Non-streaming chat ———

///|
/// ModelPort implementation — chat via OpenAI Responses API.
pub impl @posoco.ModelPort for OpenAIModelPort with fn chat(
  self : OpenAIModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
) -> @posoco.ModelResponse raise @posoco.ModelError {
  let body = build_request_body(messages, tools, options, self.config.model)
  let headers = build_headers(self.config)
  let client = @http.Client::Client(
    self.config.base_url,
    headers=headers,
  ) catch {
    e =>
      raise @posoco.ModelError::Transport(
        "Failed to create HTTP client: \{e}",
      )
  }
  let response = client.post(
    "/responses",
    body.stringify(),
  ) catch {
    e =>
      raise @posoco.ModelError::Transport("HTTP request failed: \{e}")
  }
  let body_data = client.read_all() catch {
    e =>
      raise @posoco.ModelError::Transport("Failed to read response: \{e}")
  }
  client.close()
  let body_text = body_data.text() catch {
    e =>
      raise @posoco.ModelError::ResponseParse(
        "Failed to decode response: \{e}",
      )
  }
  if response.code != 200 {
    raise @posoco.ModelError::Transport(
      "OpenAI API error \{response.code}: \{body_text}",
    )
  }
  let resp_json : Json = @json.parse(body_text) catch {
    e =>
      raise @posoco.ModelError::ResponseParse("JSON parse error: \{e}")
  }
  parse_openai_response(resp_json)
}

// ——— SSE Streaming ———

///|
/// Parse an SSE event data string into StreamChunk(s) and feed to accumulator.
fn process_sse_event(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool {
  let event_json : Json = @json.parse(data) catch {
    _ => return false
  }
  let event_type = match event_json {
    Json::Object(map) =>
      match map.get("type") {
        Some(Json::String(s)) => s
        _ => return false
      }
    _ => return false
  }
  match event_type {
    "response.output_text.delta" => {
      let token = extract_sse_string_field(event_json, "delta")
      let chunk = @posoco.StreamChunk::TextDelta(token~)
      on_chunk(chunk)
      acc.push(chunk)
      false
    }
    "response.reasoning.delta" => {
      let token = extract_sse_string_field(event_json, "delta")
      let chunk = @posoco.StreamChunk::ReasoningDelta(token~)
      on_chunk(chunk)
      acc.push(chunk)
      false
    }
    "response.function_call_arguments.delta" => {
      let index = extract_sse_int_field(event_json, "output_index")
      let delta = extract_sse_string_field(event_json, "delta")
      let chunk = @posoco.StreamChunk::ToolCallDelta(
        index=index,
        id=None,
        name=None,
        arguments_delta=Some(delta),
      )
      on_chunk(chunk)
      acc.push(chunk)
      false
    }
    "response.output_item.added" => {
      match extract_sse_output_item(event_json) {
        Some((idx, fc_id, fc_name)) => {
          let chunk = @posoco.StreamChunk::ToolCallDelta(
            index=idx,
            id=Some(fc_id),
            name=Some(fc_name),
            arguments_delta=None,
          )
          on_chunk(chunk)
          acc.push(chunk)
        }
        None => ()
      }
      false
    }
    "response.completed" => {
      match extract_usage(event_json) {
        Some(usage) => {
          let usage_chunk = @posoco.StreamChunk::Usage(usage)
          on_chunk(usage_chunk)
          acc.push(usage_chunk)
        }
        None => ()
      }
      let reason = extract_finish_from_completed(event_json)
      let finish_chunk = @posoco.StreamChunk::Finish(reason=reason)
      on_chunk(finish_chunk)
      acc.push(finish_chunk)
      true
    }
    _ => false
  }
}

///|
/// Extract FinishReason from response.completed event.
fn extract_finish_from_completed(event_json : Json) -> @posoco.FinishReason {
  let response_obj = match event_json {
    Json::Object(map) =>
      match map.get("response") {
        Some(Json::Object(rmap)) => rmap
        _ => return @posoco.FinishReason::Stop
      }
    _ => return @posoco.FinishReason::Stop
  }
  let has_fc = match response_obj.get("output") {
    Some(Json::Array(arr)) =>
      arr.exists(fn(item) {
        match item {
          Json::Object(m) =>
            match m.get("type") {
              Some(Json::String("function_call")) => true
              _ => false
            }
          _ => false
        }
      })
    _ => false
  }
  if has_fc {
    return @posoco.FinishReason::ToolCalls
  }
  match response_obj.get("status") {
    Some(Json::String("completed")) => @posoco.FinishReason::Stop
    Some(Json::String("incomplete")) => @posoco.FinishReason::Length
    Some(Json::String(s)) => @posoco.FinishReason::Other(s)
    _ => @posoco.FinishReason::Stop
  }
}

///|
fn extract_sse_string_field(json : Json, field : String) -> String {
  match json {
    Json::Object(map) =>
      match map.get(field) {
        Some(Json::String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
fn extract_sse_int_field(json : Json, field : String) -> Int {
  match json {
    Json::Object(map) =>
      match map.get(field) {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
/// Extract output item info (index, id, name) from output_item.added event.
fn extract_sse_output_item(json : Json) -> Option[(Int, String, String)] {
  match json {
    Json::Object(map) =>
      match map.get("item") {
        Some(Json::Object(item_map)) =>
          match item_map.get("type") {
            Some(Json::String("function_call")) => {
              let idx = match map.get("output_index") {
                Some(Json::Number(n, ..)) => n.to_int()
                _ => 0
              }
              let fc_id = match item_map.get("call_id") {
                Some(Json::String(s)) => s
                _ =>
                  match item_map.get("id") {
                    Some(Json::String(s)) => s
                    _ => ""
                  }
              }
              let fc_name = match item_map.get("name") {
                Some(Json::String(s)) => s
                _ => ""
              }
              Some((idx, fc_id, fc_name))
            }
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

// ——— Streaming chat ———

///|
/// ModelPort implementation — streaming chat via OpenAI Responses API + SSE.
pub impl @posoco.ModelPort for OpenAIModelPort with fn chat_streaming(
  self : OpenAIModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> @posoco.ModelResponse raise @posoco.ModelError {
  let body = build_request_body(
    messages,
    tools,
    options,
    self.config.model,
    stream=true,
  )
  let headers = build_headers(self.config)
  // Create streaming HTTP connection
  let client = @http.Client::Client(
    self.config.base_url,
    headers=headers,
  ) catch {
    e =>
      raise @posoco.ModelError::Transport(
        "Failed to create HTTP client: \{e}",
      )
  }
  // Send POST request (streaming mode)
  client.request(
    @http.RequestMethod::Post,
    "/responses",
  ) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport("Request send failed")
    }
  }
  // Write request body
  client.write(body.stringify()) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport("Write body failed")
    }
  }
  client.flush() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport("Flush failed")
    }
  }
  // End request, get response headers
  let response = client.end_request() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport("End request failed")
    }
  }
  if response.code != 200 {
    client.close()
    raise @posoco.ModelError::Transport(
      "OpenAI API error \{response.code}",
    )
  }
  // Read SSE stream line by line
  let acc = @posoco.StreamAccumulator::new()
  let mut done = false
  while !done {
    let line = client.read_until("\n") catch {
      _ => None
    }
    match line {
      Some(data) => {
        let trimmed = data.trim()
        if trimmed.has_prefix("data: ") {
          let payload = trimmed["data: ".length():].to_string()
          let pl = payload.trim()
          if pl == "[DONE]" {
            done = true
          } else if pl.length() > 0 {
            done = process_sse_event(pl.to_string(), acc, on_chunk)
          }
        }
      }
      None => done = true
    }
  }
  client.close()
  acc.to_response()
}
