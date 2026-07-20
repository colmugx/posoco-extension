///|
/// posoco_ext_deepseek — ModelPort implementation.
///
/// Implements @posoco.ModelPort for DeepSeek's /chat/completions endpoint.
/// DeepSeek-specific optimizations:
/// - Historical reasoning_content is never resent (structurally guaranteed
///   by posoco Message having no reasoning field — see encode.mbt).
/// - Append-only message ordering for context cache friendliness.
/// - SSE streaming via StreamAccumulator.

///|
/// Build HTTP headers for DeepSeek API requests.
fn build_headers(config : DeepSeekConfig) -> Map[String, String] {
  {
    "Authorization": "Bearer " + config.api_key,
    "Content-Type": "application/json",
  }
}

///|
fn api_base(config : DeepSeekConfig) -> String {
  config.base_url
}

///|
fn beta_base(config : DeepSeekConfig) -> String {
  let base = config.base_url
  if base.has_suffix("/beta") {
    base
  } else {
    base + "/beta"
  }
}

///|
/// Redacted non-2xx body metadata. Keeping this as an ADT prevents the raw
/// provider body from crossing the HTTP-error formatting boundary.
priv enum DeepSeekErrorBodySummary {
  BodyBytesUtf8(Int)
  BodyBytesInvalidUtf8(Int)
  BodyReadFailed
  BodyUnavailable
}

///|
/// Format an HTTP failure from redacted metadata.
fn format_deepseek_http_error(
  stage : String,
  status : Int,
  body_summary : DeepSeekErrorBodySummary,
) -> String {
  let summary = match body_summary {
    BodyBytesUtf8(length) => "body_bytes=\{length}, body_category=utf8"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
  "DeepSeek HTTP error (stage=\{stage}, status=\{status}, \{summary})"
}

///|
fn is_deepseek_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// Pure HTTP-status classifier. It accepts only redacted body metadata, so a
/// provider payload can never cross into the observable error message.
fn classify_deepseek_http_status(
  stage : String,
  status : Int,
  body_summary : DeepSeekErrorBodySummary,
) -> @posoco.ModelError? {
  if is_deepseek_http_success(status) {
    None
  } else {
    Some(
      @posoco.ModelError::Transport(
        format_deepseek_http_error(stage, status, body_summary),
      ),
    )
  }
}

///|
/// T07-B: drain a non-2xx response without exposing provider payloads.
async fn read_error_body_summary(
  client : @http.Client,
) -> DeepSeekErrorBodySummary {
  let data = client.read_all() catch { _ => return BodyReadFailed }
  let byte_length = data.binary().length()
  let _ = data.text() catch { _ => return BodyBytesInvalidUtf8(byte_length) }
  BodyBytesUtf8(byte_length)
}

///|
/// Pure classification for stream termination; used by the HTTP loop and
/// offline tests so EOF is never inferred from accumulated content.
priv enum DeepSeekStreamTermination {
  ExplicitTerminal
  CleanEof
  TransportFailure
}

///|
fn classify_deepseek_stream_termination(
  termination : DeepSeekStreamTermination,
) -> @posoco.ModelError? {
  match termination {
    ExplicitTerminal => None
    CleanEof =>
      Some(
        @posoco.ModelError::ResponseParse(
          "DeepSeek SSE truncated (stage=eof, terminal_marker=missing)",
        ),
      )
    TransportFailure =>
      Some(
        @posoco.ModelError::Transport(
          "DeepSeek transport failure (stage=read_stream)",
        ),
      )
  }
}

///|
/// Reject incomplete tool-call builders before delegating JSON assembly.
fn validate_deepseek_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  for tc in acc.tool_calls {
    if tc.id == "" {
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=tool.id, category=missing)",
      )
    }
    if tc.name == "" {
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=tool.name, category=missing)",
      )
    }
    if tc.arguments_json == "" {
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=tool.arguments, category=missing)",
      )
    }
    let _ : Json = @json.parse(tc.arguments_json) catch {
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek SSE parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{tc.arguments_json.length()})",
        )
    }
  }
}

///|
/// ModelPort implementation — non-streaming chat via /chat/completions.
pub impl @posoco.ModelPort for DeepSeekModelPort with fn chat(
  self : DeepSeekModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
) -> @posoco.ModelResponse raise @posoco.ModelError {
  let body = build_chat_request(
    self.ctx,
    messages,
    tools,
    options,
    self.config.model,
    false,
  )
  let headers = build_headers(self.config)
  let client = @http.Client::Client(api_base(self.config), headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=create_client)",
      )
  }
  let response = client.post("/chat/completions", body.stringify()) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=send_request)",
      )
    }
  }
  if !is_deepseek_http_success(response.code) {
    let body_summary = read_error_body_summary(client) catch {
      _ => BodyUnavailable
    }
    client.close()
    match
      classify_deepseek_http_status(
        "chat.http_status",
        response.code,
        body_summary,
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let body_data = client.read_all() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=read_response)",
      )
    }
  }
  client.close()
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=decode_utf8, category=invalid_utf8, body_bytes=\{body_data.binary().length()})",
      )
  }
  let resp_json : Json = @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=json, category=malformed, body_chars=\{body_text.length()})",
      )
  }
  decode_chat_response(resp_json)
}

///|
/// ModelPort implementation — streaming chat via /chat/completions with SSE.
/// Reads SSE events line by line, feeds StreamChunk to on_chunk + accumulator.
pub impl @posoco.ModelPort for DeepSeekModelPort with fn chat_streaming(
  self : DeepSeekModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> @posoco.ModelResponse raise @posoco.ModelError {
  let body = build_chat_request(
    self.ctx,
    messages,
    tools,
    options,
    self.config.model,
    true,
  )
  let headers = build_headers(self.config)
  let client = @http.Client::Client(api_base(self.config), headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=create_client)",
      )
  }
  client.request(@http.RequestMethod::Post, "/chat/completions") catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=send_request)",
      )
    }
  }
  client.write(body.stringify()) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=write_body)",
      )
    }
  }
  client.flush() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=flush)",
      )
    }
  }
  let response = client.end_request() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=end_request)",
      )
    }
  }
  if !is_deepseek_http_success(response.code) {
    let err_summary = read_error_body_summary(client) catch {
      _ => BodyUnavailable
    }
    client.close()
    match
      classify_deepseek_http_status(
        "chat_stream.http_status",
        response.code,
        err_summary,
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  // Read SSE stream line by line
  let acc = @posoco.StreamAccumulator::new()
  let mut done = false
  let mut data_buffer = ""
  while !done {
    let line = client.read_until("\n") catch {
      _ => {
        client.close()
        match classify_deepseek_stream_termination(TransportFailure) {
          Some(err) => raise err
          None => None
        }
      }
    }
    match line {
      Some(data) => {
        let trimmed = data.trim()
        if trimmed.has_prefix("data:") {
          let payload = trimmed[5:].trim().to_owned()
          if payload.length() > 0 {
            data_buffer = payload
            done = process_deepseek_sse(payload, acc, on_chunk)
          }
        } else if trimmed == "" && data_buffer.length() > 0 {
          // Empty line = event boundary; data already processed
          data_buffer = ""
        }
      }
      None => {
        client.close()
        match classify_deepseek_stream_termination(CleanEof) {
          Some(err) => raise err
          None => done = true
        }
      }
    }
  }
  client.close()
  match classify_deepseek_stream_termination(ExplicitTerminal) {
    Some(err) => raise err
    None => ()
  }
  validate_deepseek_stream_tool_calls(acc)
  acc.to_response()
}
