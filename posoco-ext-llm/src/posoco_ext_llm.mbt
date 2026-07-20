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
  base_url : String // default: "https://api.openai.com/v1"
  organization : String?
}

///|
/// Create an OpenAIConfig with defaults.
pub fn OpenAIConfig::new(api_key : String, model : String) -> OpenAIConfig {
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
/// Redacted non-2xx body metadata. Keeping this as an ADT prevents the raw
/// provider body from crossing the HTTP-error formatting boundary.
priv enum OpenAIErrorBodySummary {
  BodyChars(Int)
  BodyBytesUtf8(Int)
  BodyBytesInvalidUtf8(Int)
  BodyReadFailed
  BodyUnavailable
}

///|
/// Pure non-2xx body classification. Callers pass only lengths and decode
/// success, so provider payloads cannot cross this boundary.
fn classify_openai_error_body(
  byte_length : Int,
  decoded_chars : Int?,
) -> OpenAIErrorBodySummary {
  match decoded_chars {
    Some(chars) => BodyChars(chars)
    None => BodyBytesInvalidUtf8(byte_length)
  }
}

///|
/// T07-B: drain a non-2xx response without exposing provider payloads.
async fn read_error_body_summary(
  client : @http.Client,
) -> OpenAIErrorBodySummary {
  let data = client.read_all() catch { _ => return BodyReadFailed }
  let byte_length = data.binary().length()
  let _ = data.text() catch { _ => return BodyBytesInvalidUtf8(byte_length) }
  BodyBytesUtf8(byte_length)
}

///|
/// Format an HTTP failure from already-redacted metadata. The response body is
/// deliberately not accepted by this function.
fn format_openai_http_error(
  stage : String,
  status : Int,
  body_summary : OpenAIErrorBodySummary,
) -> String {
  let summary = match body_summary {
    BodyChars(length) => "body_chars=\{length}, body_category=utf8"
    BodyBytesUtf8(length) => "body_bytes=\{length}, body_category=utf8"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
  "OpenAI HTTP error (stage=\{stage}, status=\{status}, \{summary})"
}

///|
fn is_openai_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// Pure HTTP-status classification shared by streaming and non-streaming
/// paths. All 2xx statuses continue through success-body parsing; every other
/// status retains its code and only redacted body metadata.
fn classify_openai_http_status(
  stage : String,
  status : Int,
  body_summary : OpenAIErrorBodySummary,
) -> @posoco.ModelError? {
  if is_openai_http_success(status) {
    None
  } else {
    Some(
      @posoco.ModelError::Transport(
        format_openai_http_error(stage, status, body_summary),
      ),
    )
  }
}

///|
/// Build the HTTP headers for OpenAI API requests.
fn build_headers(config : OpenAIConfig) -> Map[String, String] {
  let headers : Map[String, String] = {
    "Authorization": "Bearer \{config.api_key}",
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
  stream? : Bool = false,
) -> Json {
  let input_items = messages.map(fn(m) { posoco_message_to_openai(m) })
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
  let client = @http.Client::Client(self.config.base_url, headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=create_client)",
      )
  }
  let response = client.post("/responses", body.stringify()) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=send_request)",
      )
    }
  }
  let body_data = client.read_all() catch {
    _ => {
      client.close()
      match
        classify_openai_http_status(
          "http_status",
          response.code,
          BodyReadFailed,
        ) {
        Some(err) => raise err
        None =>
          raise @posoco.ModelError::Transport(
            "OpenAI transport failure (stage=read_response)",
          )
      }
    }
  }
  client.close()
  if !is_openai_http_success(response.code) {
    let decoded_chars : Int? = Some(body_data.text().length()) catch {
      _ => None
    }
    match
      classify_openai_http_status(
        "http_status",
        response.code,
        classify_openai_error_body(body_data.binary().length(), decoded_chars),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=decode_utf8, body_bytes=\{body_data.binary().length()})",
      )
  }
  let resp_json : Json = @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=json, body_chars=\{body_text.length()})",
      )
  }
  parse_openai_response(resp_json)
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
  let client = @http.Client::Client(self.config.base_url, headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=create_client)",
      )
  }
  // Send POST request (streaming mode)
  client.request(@http.RequestMethod::Post, "/responses") catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=send_request)",
      )
    }
  }
  // Write request body
  client.write(body.stringify()) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=write_body)",
      )
    }
  }
  client.flush() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=flush)",
      )
    }
  }
  // End request, get response headers
  let response = client.end_request() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=end_request)",
      )
    }
  }
  if !is_openai_http_success(response.code) {
    // T07-B: drain only enough to retain the HTTP status plus a redacted body
    // length/encoding category. Provider payloads never enter diagnostics.
    let err_summary = read_error_body_summary(client) catch {
      _ => BodyUnavailable
    }
    client.close()
    match
      classify_openai_http_status("http_status", response.code, err_summary) {
      Some(err) => raise err
      None => ()
    }
  }
  // Read SSE stream line by line
  let acc = @posoco.StreamAccumulator::new()
  let mut done = false
  while !done {
    let line = client.read_until("\n") catch {
      _ => {
        client.close()
        match classify_stream_termination(TransportFailure) {
          Some(err) => raise err
          None => None
        }
      }
    }
    match line {
      Some(data) => {
        let trimmed = data.trim()
        if trimmed.has_prefix("data:") {
          let payload = trimmed["data:".length():].to_owned()
          let pl = payload.trim()
          if pl == "[DONE]" {
            done = true
          } else if pl.length() > 0 {
            done = process_sse_event(pl.to_owned(), acc, on_chunk)
          }
        }
      }
      None => {
        client.close()
        match classify_stream_termination(CleanEof) {
          Some(err) => raise err
          None => done = true
        }
      }
    }
  }
  client.close()
  match classify_stream_termination(ExplicitTerminal) {
    Some(err) => raise err
    None => ()
  }
  validate_stream_tool_calls(acc)
  acc.to_response()
}
