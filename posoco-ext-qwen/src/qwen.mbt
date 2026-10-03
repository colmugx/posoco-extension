///|
fn build_headers(config : QwenConfig) -> @http.Headers {
  {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
}

///|
fn chat_url(config : QwenConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
async fn QwenModelPort::post_chat_json(
  self : QwenModelPort,
  body : Json,
  stage : String,
) -> Json raise @posoco.ModelError {
  let (response, body_data) = @http.post(
    chat_url(self.config),
    body.stringify(),
    headers=build_headers(self.config),
  ) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "qwen transport failure (stage=post): " + err.to_string(),
      )
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "qwen response parse failure (stage=decode_utf8, body_bytes=\{body_data.binary().length()})",
      )
  }
  if !is_qwen_http_success(response.code) {
    match
      classify_qwen_http_error(
        stage + ".http_status",
        response.code,
        body_text,
        now_ms=@async.now(),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "qwen response parse failure (stage=json, body_chars=\{body_text.length()})",
      )
  }
}

///|
pub impl @posoco.ModelPort for QwenModelPort with fn chat(
  self : QwenModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let messages_owned = messages.to_owned()
  match stream {
    NoStream => {
      let body = build_chat_request(
        self.config,
        messages_owned,
        tools,
        options,
        false,
      )
      let completion = decode_chat_response(self.post_chat_json(body, "chat"))
      @posoco.ModelCallResult::{
        completion,
        processed_messages: messages_owned,
      }
    }
    Stream(on_chunk) => {
      let body = build_chat_request(
        self.config,
        messages_owned,
        tools,
        options,
        true,
      )
      let client = @http.post_stream(
        chat_url(self.config),
        headers=build_headers(self.config),
      ) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "qwen transport failure (stage=post_stream): " + err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "qwen transport failure (stage=write_body): " + err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "qwen transport failure (stage=end_request): " + err.to_string(),
          )
        }
      }
      if !is_qwen_http_success(response.code) {
        let body_text = read_qwen_error_body(client) catch { _ => None }
        client.close()
        match
          classify_qwen_http_error(
            "chat_stream.http_status",
            response.code,
            body_text.unwrap_or(""),
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let acc = @posoco.StreamAccumulator::StreamAccumulator()
      let mut done = false
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until("\n") catch {
          err => {
            client.close()
            raise @posoco.ModelError::Transport(
              "qwen transport failure (stage=read_stream): " + err.to_string(),
            )
          }
        }
        match line {
          Some(data) => {
            let trimmed = data.trim()
            if trimmed.has_prefix("data:") {
              let payload = trimmed[5:].trim().to_owned()
              if payload.length() > 0 {
                // Qwen may place the include_usage chunk after the completion
                // finish_reason. Keep draining until [DONE] so usage is not
                // lost. The shared parser still records the finish_reason.
                if payload == "[DONE]" {
                  let _ = process_qwen_sse(payload, acc, on_chunk)
                  done = true
                } else {
                  let _ = process_qwen_sse(payload, acc, on_chunk)
                }
              }
            }
          }
          None => {
            client.close()
            raise @posoco.ModelError::ResponseParse(
              "qwen SSE truncated (stage=eof, terminal_marker=missing)",
            )
          }
        }
        let now = @async.now()
        if now - last_yield >= 16L {
          @async.pause()
          last_yield = now
        }
      }
      client.close()
      validate_qwen_stream_tool_calls(acc)
      let completion = acc.to_completion()
      @posoco.ModelCallResult::{
        completion,
        processed_messages: messages_owned,
      }
    }
  }
}

///|
pub impl @posoco.ModelPort for QwenModelPort with fn provider_config(
  self : QwenModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=None,
  )
}

///|
pub extend QwenModelPort with @posoco.ModelPort::{provider_config, chat, compact}
