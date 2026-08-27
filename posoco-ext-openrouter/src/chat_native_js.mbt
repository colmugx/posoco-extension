///|
/// chat_native_js.mbt — ModelPort::chat impl via moonbitlang/async/http.
///
/// Compiled on native and js only: `@http` is unavailable on wasm/wasm-gc.
/// The `OpenRouterModelPort` struct, `compact`, `provider_config`, and all
/// pure helpers (build_headers, chat_url, encode, decode, SSE processing,
/// error classification) live in the target-agnostic core files and compile
/// on every backend. Only this chat method — which drives the actual HTTP
/// request/response — is target-restricted, mirroring the
/// posoco-ext-read / posoco-ext-oauth pattern.

///|
/// Drain a non-2xx response, keeping the provider's error text for the
/// failure message. Uses `@http.Client`, so it co-resides with the chat impl
/// on native+js.
async fn read_error_body(client : @http.Client) -> OpenRouterErrorBody {
  let data = client.read_all() catch { _ => return BodyReadFailed }
  let byte_length = data.binary().length()
  let text = data.text() catch { _ => return BodyBytesInvalidUtf8(byte_length) }
  BodyText(text)
}

///|
/// The `Retry-After` header off a non-2xx response, when present. OpenRouter
/// states the 429 wait here as delta seconds; the classifier routes it into
/// the typed RateLimited verdict via the kit parser.
fn retry_after_header(response : @http.Response) -> String? {
  response.headers.get(@http.CaseInsensitiveString("Retry-After"))
}

///|
/// The `X-RateLimit-Reset` header (absolute epoch seconds), when present.
fn rate_limit_reset_header(response : @http.Response) -> String? {
  response.headers.get(@http.CaseInsensitiveString("X-RateLimit-Reset"))
}

///|
/// ModelPort implementation — chat with optional streaming.
pub impl @posoco.ModelPort for OpenRouterModelPort with fn chat(
  self : OpenRouterModelPort,
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
      let resp_json = self.openrouter_post_chat_json(body, "chat")
      let completion = decode_chat_response(resp_json)
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
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let client = @http.post_stream(url, headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "openrouter transport failure (stage=post_stream): " +
            err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "openrouter transport failure (stage=write_body): " +
            err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "openrouter transport failure (stage=end_request): " +
            err.to_string(),
          )
        }
      }
      if !is_openrouter_http_success(response.code) {
        let err_body = read_error_body(client) catch { _ => BodyUnavailable }
        client.close()
        match
          classify_openrouter_http_status(
            "chat_stream.http_status",
            response.code,
            err_body,
            retry_after_header=retry_after_header(response),
            rate_limit_reset_header=rate_limit_reset_header(response),
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let state = OpenRouterStreamState()
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
            match classify_openrouter_stream_termination(TransportFailure) {
              Some(err) => raise err
              None => None
            }
          }
        }
        match line {
          Some(data) => {
            let trimmed = data.trim()
            // Only "data:"-prefixed lines carry stream bytes; heartbeat
            // comment lines (`: OPENROUTER PROCESSING`) are skipped here.
            if trimmed.has_prefix("data:") {
              let payload = trimmed[5:].trim().to_owned()
              if payload.length() > 0 {
                match wire_path {
                  Some(path) => wire_log_append(path, payload)
                  None => ()
                }
                data_buffer = payload
                // OpenRouter trails the automatic usage chunk (and heartbeat
                // comments) AFTER the finish_reason chunk, so a true return
                // from the processor (finish seen) must NOT end the loop —
                // drain until [DONE] or EOF so the tail usage lands;
                // state.terminated keeps the recorded finish reason from
                // being clobbered by the marker.
                if payload == "[DONE]" {
                  let _ = process_openrouter_sse(payload, state, on_chunk)
                  done = true
                } else {
                  let _ = process_openrouter_sse(payload, state, on_chunk)
                }
              }
            } else if trimmed == "" && data_buffer.length() > 0 {
              data_buffer = ""
            }
          }
          None => {
            client.close()
            if openrouter_eof_tolerable(state.acc) {
              let chunk = @posoco.StreamChunk::Finish(reason="tool_calls")
              on_chunk(chunk)
              state.acc.push(chunk)
              done = true
            } else {
              match classify_openrouter_stream_termination(CleanEof) {
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
      match classify_openrouter_stream_termination(ExplicitTerminal) {
        Some(err) => raise err
        None => ()
      }
      validate_openrouter_stream_tool_calls(state.acc)
      let completion = state.to_completion()
      @posoco.ModelCallResult::{
        completion,
        processed_messages: messages_owned,
      }
    }
  }
}
