///|
/// wire_responses_native_js.mbt — OpenAI Responses transport for a custom
/// endpoint. Compiled on native, wasm, and js.
///
/// Request shape lives in `request_responses.mbt`; item/tool encoding, SSE
/// event handling, and terminal validation come from
/// `posoco-kit-responses`. This file owns the URL, headers, and the stream
/// loop.

///|
async fn CustomModelPort::chat_responses(
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
      let body = build_responses_request(config, messages, tools, options)
      let (response, body_data) = @http.post(
        responses_url(config),
        body.stringify(),
        headers=build_wire_headers(config, self.request_headers),
      ) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=responses, stage=post): " +
            err.to_string(),
          )
      }
      let body_text = body_data.text() catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "custom provider response parse failure (wire=responses, stage=decode_utf8, body_bytes=\{body_data.binary().length()})",
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
            "custom provider response parse failure (wire=responses, stage=json, body_chars=\{body_text.length()})",
          )
      }
      let completion = @responses.parse_responses_response(
        provider="custom",
        resp_json,
      )
      @posoco.ModelCallResult::{ completion, processed_messages: messages, }
    }
    Stream(on_chunk) => {
      let body = build_responses_request(
        config,
        messages,
        tools,
        options,
        stream=true,
      )
      let headers = build_wire_headers(config, self.request_headers)
      let url = responses_url(config)
      let client = @http.post_stream(url, headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=responses, stage=post_stream): " +
            err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=responses, stage=write_body): " +
            err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "custom provider transport failure (wire=responses, stage=end_request): " +
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
      let sse_state = @responses.SseStreamState::SseStreamState()
      let wire_path = wire_log_path()
      let mut done = false
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until("\n") catch {
          err => {
            client.close()
            raise @posoco.ModelError::Transport(
              "custom provider transport failure (wire=responses, stage=read_stream): " +
              err.to_string(),
            )
          }
        }
        match line {
          Some(data) => {
            let trimmed = data.trim()
            if trimmed.has_prefix("data:") {
              let payload = trimmed[5:].trim().to_owned()
              if payload == "[DONE]" {
                done = true
              } else if payload.length() > 0 {
                match wire_path {
                  Some(path) => wire_log_append(path, payload)
                  None => ()
                }
                done = @responses.process_responses_sse(
                  provider="custom",
                  payload,
                  acc,
                  on_chunk,
                  state=sse_state,
                )
              }
            }
          }
          None => {
            client.close()
            match
              @responses.classify_stream_termination(
                provider="custom",
                @responses.StreamTermination::CleanEof,
              ) {
              Some(err) => raise err
              None => done = true
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
        @responses.classify_stream_termination(
          provider="custom",
          @responses.StreamTermination::ExplicitTerminal,
        ) {
        Some(err) => raise err
        None => ()
      }
      let completion = @responses.responses_stream_completion(
        provider="custom",
        acc,
      )
      @posoco.ModelCallResult::{ completion, processed_messages: messages, }
    }
  }
}
