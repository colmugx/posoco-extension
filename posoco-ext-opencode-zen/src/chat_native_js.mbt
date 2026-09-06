///|
/// Native+js only: moonbitlang/async/http (`@http`) is unavailable on wasm.

///|
async fn read_zen_error_body(client : @http.Client) -> ZenErrorBody {
  let data = client.read_all() catch { _ => return BodyReadFailed }
  let byte_length = data.binary().length()
  let text = data.text() catch { _ => return BodyBytesInvalidUtf8(byte_length) }
  BodyText(text)
}

///|
pub impl @posoco.ModelPort for OpenCodeZenModelPort with fn chat(
  self : OpenCodeZenModelPort,
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
        messages_owned,
        tools,
        options,
        self.config.model,
        false,
        self.config.thinking,
        self.config.reasoning_effort,
        self.config.supports_images,
      )
      let resp_json = self.zen_post_chat_json(body, "chat")
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
        self.config.thinking,
        self.config.reasoning_effort,
        self.config.supports_images,
      )
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let client = @http.post_stream(url, headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "opencode-zen transport failure (stage=post_stream): " +
            err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "opencode-zen transport failure (stage=write_body): " +
            err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "opencode-zen transport failure (stage=end_request): " +
            err.to_string(),
          )
        }
      }
      if !is_zen_http_success(response.code) {
        let err_body = read_zen_error_body(client) catch {
          _ => BodyUnavailable
        }
        client.close()
        match
          classify_zen_http_status(
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
      // Optional wire log (POSOCO_WIRE_LOG): verbatim raw SSE data payloads,
      // one per line, for diagnosing provider streams. js/bun only today.
      let wire_path = wire_log_path()
      let mut done = false
      let mut data_buffer = ""
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until("\n") catch {
          _ => {
            client.close()
            match classify_zen_stream_termination(TransportFailure) {
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
                done = process_zen_sse(payload, acc, on_chunk)
              }
            } else if trimmed == "" && data_buffer.length() > 0 {
              data_buffer = ""
            }
          }
          None => {
            client.close()
            if zen_eof_tolerable(acc) {
              let chunk = @posoco.StreamChunk::Finish(reason="tool_calls")
              on_chunk(chunk)
              acc.push(chunk)
              done = true
            } else {
              match classify_zen_stream_termination(CleanEof) {
                Some(err) => raise err
                None => done = true
              }
            }
          }
        }
        // A buffered SSE burst makes read_until complete without suspending,
        // so this loop can spin through the whole stream in one coroutine
        // chain and the host never dispatches stdin (ESC/interrupt). Yield at
        // most every 16ms so the event loop can breathe; the pause is also a
        // cancellation point, which is what makes abort responsive.
        let now = @async.now()
        if now - last_yield >= 16L {
          @async.pause() catch {
            // Turn abort is mailbox-driven (the pump checks abort_requested
            // between effects), so a cancelled pause is safe to ride over;
            // the next read on a torn-down client errors out of the loop.
            _ => ()
          }
          last_yield = now
        }
      }
      client.close()
      match classify_zen_stream_termination(ExplicitTerminal) {
        Some(err) => raise err
        None => ()
      }
      validate_zen_stream_tool_calls(acc)
      let completion = acc.to_completion()
      @posoco.ModelCallResult::{
        completion,
        processed_messages: messages_owned,
      }
    }
  }
}
