///|
/// posoco_ext_deepseek — ModelPort implementation.
///
/// Implements @posoco.ModelPort for DeepSeek's /chat/completions endpoint.
/// Uses @http.post / @http.post_stream with the full endpoint URL.

///|
/// Build HTTP headers for DeepSeek API requests.
fn build_headers(config : DeepSeekConfig) -> @http.Headers {
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
/// DeepSeek's provider-owned thinking config. An empty `reasoning_effort`
/// means thinking is switched off: the wire carries `{type: "disabled"}` and
/// no `reasoning_effort` field, regardless of the advertised effort list.
fn DeepSeekModelPort::default_thinking_config(
  self : DeepSeekModelPort,
) -> (Json, String?) {
  if self.config.thinking_efforts.is_empty() ||
    self.config.reasoning_effort == "" {
    (Json::object({ "type": Json::string("disabled") }), None)
  } else {
    (enabled_thinking_json(), Some(self.config.reasoning_effort))
  }
}

///|
/// ModelPort implementation — chat with optional streaming.
pub impl @posoco.ModelPort for DeepSeekModelPort with fn chat(
  self : DeepSeekModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let (thinking_json, effort_str) = self.default_thinking_config()
  let messages_owned = messages.to_owned()
  match stream {
    NoStream => {
      let body = build_chat_request(
        self.ctx,
        messages_owned,
        tools,
        options,
        self.config.model,
        false,
        thinking_json,
        effort_str,
      )
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "DeepSeek transport failure (stage=post): " + err.to_string(),
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
      let completion = decode_chat_response(resp_json)
      @posoco.ModelCallResult::{
        completion,
        processed_messages: messages_owned,
      }
    }
    Stream(on_chunk) => {
      let body = build_chat_request(
        self.ctx,
        messages_owned,
        tools,
        options,
        self.config.model,
        true,
        thinking_json,
        effort_str,
      )
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let client = @http.post_stream(url, headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "DeepSeek transport failure (stage=post_stream): " + err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "DeepSeek transport failure (stage=write_body): " + err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "DeepSeek transport failure (stage=end_request): " + err.to_string(),
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
      let acc = @posoco.StreamAccumulator::StreamAccumulator()
      // Forward typed StreamChunks directly to the host callback. The
      // accumulator is owned by process_deepseek_sse, which pushes every chunk
      // exactly once; pushing here too would double every text/reasoning delta.
      let mut done = false
      let mut data_buffer = ""
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until("\n") catch {
          err => {
            client.close()
            raise @posoco.ModelError::Transport(
              "DeepSeek transport failure (stage=read_stream): " +
              err.to_string(),
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
                done = process_deepseek_sse(payload, acc, on_chunk)
              }
            } else if trimmed == "" && data_buffer.length() > 0 {
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
      match classify_deepseek_stream_termination(ExplicitTerminal) {
        Some(err) => raise err
        None => ()
      }
      validate_deepseek_stream_tool_calls(acc)
      let completion = acc.to_completion()
      @posoco.ModelCallResult::{
        completion,
        processed_messages: messages_owned,
      }
    }
  }
}

///|
/// ModelPort implementation — compact. DeepSeek has no dedicated compact
/// endpoint; the modelport declines by raising ResponseParse so the pump's
/// compact safe-point reports a typed failure rather than silently no-op'ing.
pub impl @posoco.ModelPort for DeepSeekModelPort with fn compact(
  _self : DeepSeekModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "DeepSeek does not implement compact (no provider-side endpoint)",
  )
}

///|
/// ModelPort implementation — provider_config. Declares which reasoning_effort
/// values this modelport accepts (M3.7 pull-based config learning).
pub impl @posoco.ModelPort for DeepSeekModelPort with fn provider_config(
  _self : DeepSeekModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}
