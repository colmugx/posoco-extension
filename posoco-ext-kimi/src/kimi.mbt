///|
/// posoco_ext_kimi — ModelPort implementation.
///
/// Implements @posoco.ModelPort for kimi's /chat/completions endpoint.
/// Uses @http.post / @http.post_stream with the full endpoint URL.

///|
/// Build HTTP headers for kimi API requests. Identity headers (User-Agent +
/// X-Msh-*) form the base layer when the provider impersonates kimi-code-cli;
/// Authorization and Content-Type always override any same-named default so
/// the chat wire contract stays authoritative.
fn build_headers(config : KimiConfig) -> @http.Headers {
  let headers : @http.Headers = Map([])
  for k, v in config.identity_headers {
    headers[k] = v
  }
  headers["Authorization"] = "Bearer \{config.api_key}"
  headers["Content-Type"] = "application/json"
  headers
}

///|
/// The full chat completions URL: base_url + endpoint_prefix + /chat/completions.
fn chat_url(config : KimiConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
/// Resolve thinking config based on model name (K7).
/// - kimi-k3: thinking permanently on, supports reasoning_effort (low/high/max).
///   Do NOT send thinking object; send top-level reasoning_effort only.
/// - kimi-k2.7-code: thinking permanently on, keep must be "all".
///   Send thinking={type:"enabled",keep:"all"}.
/// - kimi-k2.6: thinking toggleable, must NOT set temperature, keep optional.
///   Default: enabled with keep="all".
/// - kimi-k2.5: thinking toggleable, keep not supported.
/// - default/fallback: enabled with keep="all", effort="high".
///
/// Returns (thinking_json, cache_key_placeholder). The cache_key is handled
/// separately in build_chat_request.
fn resolve_thinking_config(
  model : String,
  thinking_efforts : Array[String],
  effort : String,
) -> (Json, String?) {
  // A live model catalog may explicitly advertise no thinking support.  Do
  // not send a provider-family default in that case.
  if thinking_efforts.is_empty() {
    (Json::object({ "type": Json::string("disabled") }), None)
  } else if model == "kimi-k3" {
    // k3: thinking permanently enabled and effort is top-level.
    (Json::null(), Some(effort))
  } else if model == "kimi-k2.7-code" {
    // k2.7-code: permanently on, keep must be "all", cannot disable.
    (enabled_thinking_json(Some(effort)), None)
  } else if model == "kimi-k2.6" {
    // k2.6: enabled with keep="all". Caller must NOT set temperature.
    (enabled_thinking_json(Some(effort)), None)
  } else if model == "kimi-k2.5" {
    // k2.5: enabled, keep not supported (omit keep).
    (enabled_thinking_json(Some(effort)), None)
  } else {
    // Fallback: enabled with keep="all" and provider-selected effort.
    (enabled_thinking_json(Some(effort)), None)
  }
}

///|
/// ModelPort implementation — chat with optional streaming.
pub impl @posoco.ModelPort for KimiModelPort with fn chat(
  self : KimiModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let (thinking_json, reasoning_effort_str) = resolve_thinking_config(
    self.config.model,
    self.config.thinking_efforts,
    self.config.reasoning_effort,
  )
  // k2.6 must not set temperature — strip it if present.
  let safe_options : @posoco.ChatOptions = if self.config.model == "kimi-k2.6" {
    @posoco.ChatOptions::{
      temperature: None,
      max_output_tokens: options.max_output_tokens,
    }
  } else {
    options
  }
  let messages_owned = messages.to_owned()
  match stream {
    NoStream => {
      let body = build_chat_request(
        self.ctx,
        messages_owned,
        tools,
        safe_options,
        self.config.model,
        false,
        thinking_json,
        None, // cache_key — host passes session_id via call_options
        reasoning_effort_str~,
        supports_images=self.config.supports_images,
      )
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "kimi transport failure (stage=post): " + err.to_string(),
          )
      }
      if !is_kimi_http_success(response.code) {
        let body_text = body_data.text() catch { _ => "" }
        match
          classify_kimi_http_status(
            "chat.http_status",
            response.code,
            BodyBytesUtf8(body_data.binary().length()),
            body_text~,
            retry_after=retry_after_header(response),
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let body_text = body_data.text() catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "kimi response parse failure (stage=decode_utf8, category=invalid_utf8, body_bytes=\{body_data.binary().length()})",
          )
      }
      let resp_json : Json = @json.parse(body_text) catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "kimi response parse failure (stage=json, category=malformed, body_chars=\{body_text.length()})",
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
        safe_options,
        self.config.model,
        true,
        thinking_json,
        None,
        reasoning_effort_str~,
        supports_images=self.config.supports_images,
      )
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let client = @http.post_stream(url, headers~) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "kimi transport failure (stage=post_stream): " + err.to_string(),
          )
      }
      client.write(body.stringify()) catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "kimi transport failure (stage=write_body): " + err.to_string(),
          )
        }
      }
      let response = client.end_request() catch {
        err => {
          client.close()
          raise @posoco.ModelError::Transport(
            "kimi transport failure (stage=end_request): " + err.to_string(),
          )
        }
      }
      if !is_kimi_http_success(response.code) {
        let retry_after = retry_after_header(response)
        let err_body = read_error_body_text(client) catch { _ => None }
        client.close()
        match
          classify_kimi_http_status(
            "chat_stream.http_status",
            response.code,
            match err_body {
              Some(text) => BodyBytesUtf8(text.length())
              None => BodyUnavailable
            },
            body_text=match err_body {
              Some(text) => text
              None => ""
            },
            retry_after~,
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let acc = @posoco.StreamAccumulator::StreamAccumulator()
      // Forward typed StreamChunks directly to the host callback. The
      // accumulator is owned by process_kimi_sse, which pushes every chunk
      // exactly once; pushing here too would double every text/reasoning delta.
      let mut done = false
      let mut data_buffer = ""
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until("\n") catch {
          err => {
            client.close()
            raise @posoco.ModelError::Transport(
              "Kimi transport failure (stage=read_stream): " + err.to_string(),
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
                done = process_kimi_sse(payload, acc, on_chunk)
              }
            } else if trimmed == "" && data_buffer.length() > 0 {
              data_buffer = ""
            }
          }
          None => {
            client.close()
            match classify_kimi_stream_termination(CleanEof) {
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
      match classify_kimi_stream_termination(ExplicitTerminal) {
        Some(err) => raise err
        None => ()
      }
      validate_kimi_stream_tool_calls(acc)
      let completion = acc.to_completion()
      @posoco.ModelCallResult::{
        completion,
        processed_messages: messages_owned,
      }
    }
  }
}

///|
/// ModelPort implementation — compact lives in compact.mbt (kit-based
/// summary of everything older than the last two user/assistant messages).

///|
/// ModelPort implementation — provider_config. Reports the discovery
/// endpoint's context capacity so the Agent can size auto-compact from the
/// active model's own window, plus kimi-cli's trigger ratio (0.85) so the
/// core auto-compact fires at the same point kimi-code would.
pub impl @posoco.ModelPort for KimiModelPort with fn provider_config(
  self : KimiModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=Some(0.85),
  )
}
