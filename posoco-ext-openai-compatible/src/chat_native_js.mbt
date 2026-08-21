///|
/// chat_native_js.mbt — ModelPort::chat impl via moonbitlang/async/http.
///
/// Compiled on native and js only: `@http` is unavailable on wasm/wasm-gc.
/// The `OpenAICompatibleModelPort` struct, `compact`, `provider_config`, and
/// all pure helpers (build_headers, chat_url, streamchunk_to_json, SSE
/// processing, error classification) live in the target-agnostic core files
/// and compile on every backend. Only this chat method — which drives the
/// actual HTTP request/response — is target-restricted, mirroring the
/// posoco-ext-read / posoco-ext-oauth pattern.

///|
/// Drain a non-2xx response, keeping the provider's error text for the
/// failure message. Uses `@http.Client`, so it co-resides with the chat impl
/// on native+js.
async fn read_error_body(client : @http.Client) -> OaiCompatErrorBody {
  let data = client.read_all() catch { _ => return BodyReadFailed }
  let byte_length = data.binary().length()
  let text = data.text() catch { _ => return BodyBytesInvalidUtf8(byte_length) }
  BodyText(text)
}

///|
/// ModelPort implementation — chat with optional streaming.
pub impl @posoco.ModelPort for OpenAICompatibleModelPort with fn chat(
  self : OpenAICompatibleModelPort,
  _scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  match stream {
    NoStream => {
      let body = build_chat_request(
        messages,
        tools,
        options,
        self.config.model,
        false,
        self.config.thinking,
        self.config.reasoning_effort,
      )
      let headers = build_headers(self.config, self.request_headers)
      let url = chat_url(self.config)
      let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "openai-compatible transport failure (stage=post): " +
            err.to_string(),
          )
      }
      if !is_oai_compat_http_success(response.code) {
        let byte_length = body_data.binary().length()
        let text = body_data.text() catch {
          _ =>
            raise @posoco.ModelError::Transport(
              format_oai_compat_http_error(
                "chat.http_status",
                response.code,
                BodyBytesInvalidUtf8(byte_length),
              ),
            )
        }
        match
          classify_oai_compat_http_status(
            "chat.http_status",
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
            "openai-compatible response parse failure (stage=decode_utf8, category=invalid_utf8, body_bytes=\{body_data.binary().length()})",
          )
      }
      let resp_json : Json = @json.parse(body_text) catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "openai-compatible response parse failure (stage=json, category=malformed, body_chars=\{body_text.length()})",
          )
      }
      let completion = decode_chat_response(resp_json)
      @posoco.ModelCallResult::{ completion, processed_messages: messages }
    }
    Stream(on_chunk) => {
      let body = build_chat_request(
        messages,
        tools,
        options,
        self.config.model,
        true,
        self.config.thinking,
        self.config.reasoning_effort,
      )
      let headers = build_headers(self.config, self.request_headers)
      let url = chat_url(self.config)
      let client = @http.post_stream(url, headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "openai-compatible transport failure (stage=post_stream): " +
            err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "openai-compatible transport failure (stage=write_body): " +
            err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "openai-compatible transport failure (stage=end_request): " +
            err.to_string(),
          )
        }
      }
      if !is_oai_compat_http_success(response.code) {
        let err_body = read_error_body(client) catch { _ => BodyUnavailable }
        client.close()
        match
          classify_oai_compat_http_status(
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
      let on_typed = fn(chunk : @posoco.StreamChunk) {
        on_chunk(streamchunk_to_json(chunk))
      }
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
            match classify_oai_compat_stream_termination(TransportFailure) {
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
                done = process_oai_compat_sse(payload, acc, on_typed)
              }
            } else if trimmed == "" && data_buffer.length() > 0 {
              data_buffer = ""
            }
          }
          None => {
            client.close()
            if oai_compat_eof_tolerable(acc) {
              let chunk = @posoco.StreamChunk::Finish(reason="tool_calls")
              on_typed(chunk)
              acc.push(chunk)
              done = true
            } else {
              match classify_oai_compat_stream_termination(CleanEof) {
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
      match classify_oai_compat_stream_termination(ExplicitTerminal) {
        Some(err) => raise err
        None => ()
      }
      validate_oai_compat_stream_tool_calls(acc)
      let completion = acc.to_completion()
      @posoco.ModelCallResult::{ completion, processed_messages: messages }
    }
  }
}
