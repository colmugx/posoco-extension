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
    "Authorization": "Bearer \{config.api_key}",
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
