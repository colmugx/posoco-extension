///|
fn build_headers(config : ZaiConfig) -> @http.Headers {
  {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
    "Accept-Language": "en-US,en",
  }
}

///|
fn chat_url(config : ZaiConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
/// Thinking wire state derived from config: enabled when an effort is set or
/// the model is an always-on GLM-4.x thinker; `reasoning_effort` is sent only
/// for models that declare efforts.
fn ZaiModelPort::thinking_state(self : ZaiModelPort) -> (Bool, String?) {
  match zai_model_info(self.config.model) {
    Some(info) =>
      if info.thinking_always {
        (true, None)
      } else if info.efforts.is_empty() {
        (false, None)
      } else if self.config.reasoning_effort == "" {
        (false, None)
      } else {
        (true, Some(self.config.reasoning_effort))
      }
    None => (self.config.reasoning_effort != "", None)
  }
}

///|
pub impl @posoco.ModelPort for ZaiModelPort with fn chat(
  self : ZaiModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let (thinking_enabled, effort_str) = self.thinking_state()
  let messages_owned = messages.to_owned()
  match stream {
    NoStream => {
      let body = build_chat_request(
        messages_owned,
        tools,
        options,
        self.config.model,
        false,
        thinking_enabled,
        effort_str,
      )
      let (response, body_data) = @http.post(
        chat_url(self.config),
        body.stringify(),
        headers=build_headers(self.config),
      ) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "zai transport failure (stage=post): " + err.to_string(),
          )
      }
      let body_text = body_data.text() catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "zai response parse failure (stage=decode_utf8, body_bytes=\{body_data.binary().length()})",
          )
      }
      if !is_zai_http_success(response.code) {
        match
          classify_zai_http_error(
            "chat.http_status",
            response.code,
            body_text,
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let resp_json : Json = @json.parse(body_text) catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "zai response parse failure (stage=json, body_chars=\{body_text.length()})",
          )
      }
      let completion = decode_chat_response(resp_json)
      @posoco.ModelCallResult::{
        completion,
        processed_messages: messages_owned,
      }
    }
    Stream(on_chunk) => {
      let body = build_chat_request(
        messages_owned,
        tools,
        options,
        self.config.model,
        true,
        thinking_enabled,
        effort_str,
      )
      let client = @http.post_stream(
        chat_url(self.config),
        headers=build_headers(self.config),
      ) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "zai transport failure (stage=post_stream): " + err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "zai transport failure (stage=write_body): " + err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "zai transport failure (stage=end_request): " + err.to_string(),
          )
        }
      }
      if !is_zai_http_success(response.code) {
        let err_body = read_error_body_text(client) catch { _ => None }
        client.close()
        match
          classify_zai_http_error(
            "chat_stream.http_status",
            response.code,
            match err_body {
              Some(text) => text
              None => ""
            },
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let acc = @posoco.StreamAccumulator::StreamAccumulator()
      // Forward typed StreamChunks directly to the host callback.
      let mut done = false
      let mut data_buffer = ""
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until("\n") catch {
          err => {
            client.close()
            raise @posoco.ModelError::Transport(
              "zai transport failure (stage=read_stream): " + err.to_string(),
            )
          }
        }
        match line {
          Some(data) => {
            let trimmed = data.trim()
            if trimmed.has_prefix("data:") {
              let payload = trimmed[5:].trim().to_owned()
              if payload.length() > 0 {
                data_buffer = payload
                done = process_zai_sse(payload, acc, on_chunk)
              }
            } else if trimmed == "" && data_buffer.length() > 0 {
              data_buffer = ""
            }
          }
          None => {
            client.close()
            raise @posoco.ModelError::ResponseParse(
              "zai SSE truncated (stage=eof, terminal_marker=missing)",
            )
          }
        }
        // Yield at most every 16ms so the event loop can breathe during a
        // buffered SSE burst; the pause is also a cancellation point.
        let now = @async.now()
        if now - last_yield >= 16L {
          @async.pause() catch {
            _ => ()
          }
          last_yield = now
        }
      }
      client.close()
      validate_zai_stream_tool_calls(acc)
      let completion = acc.to_completion()
      @posoco.ModelCallResult::{
        completion,
        processed_messages: messages_owned,
      }
    }
  }
}

///|
fn validate_zai_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  for tc in acc.tool_calls {
    if tc.id == "" {
      raise @posoco.ModelError::ResponseParse(
        "zai SSE parse failure (stage=tool.id, category=missing)",
      )
    }
    if tc.name == "" {
      raise @posoco.ModelError::ResponseParse(
        "zai SSE parse failure (stage=tool.name, category=missing)",
      )
    }
    if tc.arguments_json() == "" {
      raise @posoco.ModelError::ResponseParse(
        "zai SSE parse failure (stage=tool.arguments, category=missing)",
      )
    }
    let _ : Json = @json.parse(tc.arguments_json()) catch {
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "zai SSE parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{tc.arguments_json().length()})",
        )
    }
  }
}

///|
pub impl @posoco.ModelPort for ZaiModelPort with fn provider_config(
  _self : ZaiModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}
