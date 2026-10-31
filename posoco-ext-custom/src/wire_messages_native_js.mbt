///|
/// wire_messages_native_js.mbt — Anthropic Messages transport for a custom
/// endpoint. Compiled on native, wasm, and js.
///
/// Request shape lives in `request_messages.mbt`; block encoding, SSE event
/// processing, and terminal classification come from
/// `posoco-kit-messages`. This file owns the URL, headers, and the stream
/// loop.

///|
async fn CustomModelPort::chat_messages(
  self : CustomModelPort,
  scope : @posoco.InvocationScope,
  config : CustomConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let _ = scope
  match stream {
    NoStream => {
      let body = build_messages_request(config, messages, tools, options)
      let (response, body_data) = @http.post(
        messages_url(config),
        body.stringify(),
        headers=build_wire_headers(config, self.request_headers),
      ) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=messages, stage=post): " +
            err.to_string(),
          )
      }
      let body_text = body_data.text() catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "custom provider response parse failure (wire=messages, stage=decode_utf8, body_bytes=\{body_data.binary().length()})",
          )
      }
      if !is_custom_http_success(response.code) {
        match
          classify_custom_http_status(
            "chat.http_status",
            response.code,
            BodyText(body_text),
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let resp_json : Json = @json.parse(body_text) catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "custom provider response parse failure (wire=messages, stage=json, body_chars=\{body_text.length()})",
          )
      }
      let result = @messages.parse_response(provider="custom", resp_json)
      @posoco.ModelCallResult::{
        completion: result.completion,
        processed_messages: messages,
      }
    }
    Stream(on_chunk) => {
      let body = build_messages_request(
        config,
        messages,
        tools,
        options,
        stream=true,
      )
      let client = @http.post_stream(
        messages_url(config),
        headers=build_wire_headers(config, self.request_headers),
      ) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=messages, stage=post_stream): " +
            err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=messages, stage=write_body): " +
            err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=messages, stage=end_request): " +
            err.to_string(),
          )
        }
      }
      if !is_custom_http_success(response.code) {
        let err_body = read_custom_error_body(client) catch {
          _ => BodyUnavailable
        }
        client.close()
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
      let state = @messages.MessagesSseState::MessagesSseState()
      let decoder = @messages.SseDecoder::SseDecoder()
      let wire_path = wire_log_path()
      let mut done = false
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until("\n") catch {
          err => {
            client.close()
            raise @posoco.ModelError::Transport(
              "custom provider transport failure (wire=messages, stage=read_stream): " +
              err.to_string(),
            )
          }
        }
        match line {
          Some(data) =>
            for event in decoder.push(data + "\n") {
              match wire_path {
                Some(path) => wire_log_append(path, event.data)
                None => ()
              }
              errdefer client.close()
              done = @messages.process_messages_event(
                provider="custom",
                event_name=event.name,
                data=event.data,
                acc~,
                on_chunk~,
                state~,
              )
            }
          None => {
            client.close()
            match
              @messages.classify_stream_termination(
                provider="custom",
                @messages.StreamTermination::CleanEof,
              ) {
              Some(err) => raise err
              None => done = true
            }
          }
        }
        // Same yield discipline as the other wire loops: a buffered SSE burst
        // must not starve the host event loop, and the pause doubles as the
        // cancellation point.
        let now = @async.now()
        if now - last_yield >= 16L {
          @async.pause()
          last_yield = now
        }
      }
      client.close()
      match
        @messages.classify_stream_termination(
          provider="custom",
          @messages.StreamTermination::ExplicitTerminal,
        ) {
        Some(err) => raise err
        None => ()
      }
      let result = @messages.messages_stream_result(
        provider="custom",
        acc~,
        state~,
      )
      @posoco.ModelCallResult::{
        completion: result.completion,
        processed_messages: messages,
      }
    }
  }
}
