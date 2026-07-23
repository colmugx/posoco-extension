///|
/// posoco_ext_deepseek — ModelPort implementation.
///
/// Implements @posoco.ModelPort for DeepSeek's /chat/completions endpoint.
/// Uses @http.post / @http.post_stream with the full endpoint URL, same
/// pattern as elyra's HttpStreamingPort.

///|
/// Build HTTP headers for DeepSeek API requests.
fn build_headers(config : DeepSeekConfig) -> Map[String, String] {
  {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
}

///|
/// The full chat completions URL: base_url + endpoint_prefix + /chat/completions.
fn chat_url(config : DeepSeekConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
/// The full FIM completions URL (beta variant): base_url + /beta + endpoint_prefix + /completions.
fn fim_url(config : DeepSeekConfig) -> String {
  let base = if config.base_url.has_suffix("/beta") {
    config.base_url
  } else {
    config.base_url + "/beta"
  }
  base + config.endpoint_prefix + "/completions"
}

///|
/// The full prefix-completion URL (beta variant): base_url + /beta + endpoint_prefix + /chat/completions.
fn prefix_url(config : DeepSeekConfig) -> String {
  let base = if config.base_url.has_suffix("/beta") {
    config.base_url
  } else {
    config.base_url + "/beta"
  }
  base + config.endpoint_prefix + "/chat/completions"
}

///|
/// ModelPort implementation — non-streaming chat via @http.post.
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
  let url = chat_url(self.config)
  let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=post)",
      )
  }
  if !is_deepseek_http_success(response.code) {
    match
      classify_deepseek_http_status(
        "chat.http_status",
        response.code,
        BodyBytesUtf8(body_data.binary().length()),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
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
/// ModelPort implementation — streaming chat via @http.post_stream + SSE.
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
  let url = chat_url(self.config)
  let client = @http.post_stream(url, headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=post_stream)",
      )
  }
  client.write(body.stringify()) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=write_body)",
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
