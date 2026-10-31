///|
/// wire_chat_completions_native_js.mbt — the standard OpenAI Chat Completions
/// transport for a custom endpoint.
///
/// Compiled on native, wasm, and js (`@http` is unavailable on wasm-gc). The
/// dialect quirks (SSE tolerance, content encoding, prompt-cache helpers,
/// transient classification) come from `posoco-kit-chat-completions`; this
/// file owns the URL, the credential header, and the stream loop.

///|
fn chat_url(config : CustomConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
/// POST one chat-completions request body and decode the JSON response, with
/// the transport/status/parse error classification every chat-wire call
/// shares. `stage` labels the failure messages (e.g. "chat", "compact").
async fn CustomModelPort::custom_post_chat_json(
  self : CustomModelPort,
  config : CustomConfig,
  body : Json,
  stage : String,
) -> Json raise @posoco.ModelError {
  let headers = build_wire_headers(config, self.request_headers)
  let url = chat_url(config)
  let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "custom provider transport failure (wire=chat_completions, stage=" +
        stage +
        ".post): " +
        err.to_string(),
      )
  }
  if !is_custom_http_success(response.code) {
    let byte_length = body_data.binary().length()
    let text = body_data.text() catch {
      _ =>
        raise @posoco.ModelError::Transport(
          format_custom_http_error(
            stage + ".http_status",
            response.code,
            BodyBytesInvalidUtf8(byte_length),
          ),
        )
    }
    self.learn_prompt_cache_key_rejection(text)
    match
      classify_custom_http_status(
        "\{stage}.http_status",
        response.code,
        BodyText(text),
        now_ms=@async.now(),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "custom provider response parse failure (wire=chat_completions, stage=decode_utf8, category=invalid_utf8, body_bytes=\{body_data.binary().length()})",
      )
  }
  @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "custom provider response parse failure (wire=chat_completions, stage=json, category=malformed, body_chars=\{body_text.length()})",
      )
  }
}

///|
async fn CustomModelPort::chat_chat_completions(
  self : CustomModelPort,
  scope : @posoco.InvocationScope,
  config : CustomConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let cache_key = custom_resolve_cache_key(
    config.send_prompt_cache_key,
    self.prompt_cache_key_rejected_now(),
    scope.session_id.to_string(),
  )
  match stream {
    NoStream => {
      let body = build_chat_request(
        messages,
        tools,
        options,
        config.model,
        false,
        config.reasoning_effort,
        cache_key,
        config.supports_images,
      )
      let resp_json = self.custom_post_chat_json(config, body, "chat")
      let completion = decode_chat_response(resp_json)
      @posoco.ModelCallResult::{ completion, processed_messages: messages, }
    }
    Stream(on_chunk) => {
      let body = build_chat_request(
        messages,
        tools,
        options,
        config.model,
        true,
        config.reasoning_effort,
        cache_key,
        config.supports_images,
      )
      let headers = build_wire_headers(config, self.request_headers)
      let url = chat_url(config)
      let client = @http.post_stream(url, headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=chat_completions, stage=post_stream): " +
            err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=chat_completions, stage=write_body): " +
            err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=chat_completions, stage=end_request): " +
            err.to_string(),
          )
        }
      }
      if !is_custom_http_success(response.code) {
        let err_body = read_custom_error_body(client) catch {
          _ => BodyUnavailable
        }
        client.close()
        match err_body {
          BodyText(text) => self.learn_prompt_cache_key_rejection(text)
          _ => ()
        }
        match
          classify_custom_http_status(
            "chat_stream.http_status",
            response.code,
            err_body,
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let acc = @posoco.StreamAccumulator::StreamAccumulator()
      let wire_path = wire_log_path()
      let mut done = false
      let mut data_buffer = ""
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until("\n") catch {
          err => {
            client.close()
            match
              classify_custom_stream_termination(
                wire="chat_completions",
                TransportFailure,
              ) {
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
                match wire_path {
                  Some(path) => wire_log_append(path, payload)
                  None => ()
                }
                data_buffer = payload
                done = process_custom_chat_sse(payload, acc, on_chunk)
              }
            } else if trimmed == "" && data_buffer.length() > 0 {
              data_buffer = ""
            }
          }
          None => {
            client.close()
            if custom_chat_eof_tolerable(acc) {
              let chunk = @posoco.StreamChunk::Finish(reason="tool_calls")
              on_chunk(chunk)
              acc.push(chunk)
              done = true
            } else {
              match
                classify_custom_stream_termination(
                  wire="chat_completions",
                  CleanEof,
                ) {
                Some(err) => raise err
                None => done = true
              }
            }
          }
        }
        let now = @async.now()
        if now - last_yield >= 16L {
          @async.pause()
          last_yield = now
        }
      }
      client.close()
      match
        classify_custom_stream_termination(
          wire="chat_completions",
          ExplicitTerminal,
        ) {
        Some(err) => raise err
        None => ()
      }
      validate_custom_chat_stream_tool_calls(acc)
      let completion = acc.to_completion()
      @posoco.ModelCallResult::{ completion, processed_messages: messages, }
    }
  }
}
