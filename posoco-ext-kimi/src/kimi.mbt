///|
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
fn responses_url(config : KimiConfig) -> String {
  config.base_url + config.endpoint_prefix + "/responses"
}

///|
fn KimiModelPort::prompt_cache_key_for(
  self : KimiModelPort,
  session_id : String,
) -> String? {
  if self.config.send_prompt_cache_key && !self.prompt_cache_key_rejected {
    Some(@chatkit.derive_prompt_cache_key(session_id))
  } else {
    None
  }
}

///|
fn KimiModelPort::learn_prompt_cache_key_rejection(
  self : KimiModelPort,
  body_text : String,
) -> Unit {
  if !self.prompt_cache_key_rejected &&
    @chatkit.is_prompt_cache_key_rejection(body_text) {
    self.prompt_cache_key_rejected = true
  }
}

///|
fn attach_kimi_stream_reasoning(
  completion : @posoco.Completion,
  state : @responses.SseStreamState,
) -> @posoco.Completion {
  if state.items.is_empty() {
    return completion
  }
  let content = match completion.message.reasoning {
    Some(r) => if r.content == "" { state.summary } else { r.content }
    None => state.summary
  }
  @posoco.Completion::Completion(
    content=completion.message.content,
    tool_calls=completion.message.tool_calls,
    reasoning=Some(@posoco.Reasoning::{
      content,
      raw: Some(Json::array(state.items)),
    }),
    finish_reason=completion.message.finish_reason,
    usage=completion.usage,
  )
}

///|
pub impl @posoco.ModelPort for KimiModelPort with fn chat(
  self : KimiModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let messages_owned = messages.to_owned()
  let cache_key = self.prompt_cache_key_for(scope.session_id.to_string())
  match stream {
    NoStream => self.chat_nonstream(messages_owned, tools, options, cache_key)
    Stream(on_chunk) =>
      self.chat_stream(messages_owned, tools, options, cache_key, on_chunk)
  }
}

///|
async fn KimiModelPort::chat_nonstream(
  self : KimiModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  cache_key : String?,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let body = build_responses_request(
    messages,
    tools,
    options,
    self.config.model,
    false,
    cache_key,
    reasoning_effort=Some(self.config.reasoning_effort),
  )
  let headers = build_headers(self.config)
  let (response, body_data) = @http.post(
    responses_url(self.config),
    body.stringify(),
    headers~,
  ) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "kimi transport failure (stage=post): " + err.to_string(),
      )
  }
  if !is_kimi_http_success(response.code) {
    let body_text = body_data.text() catch { _ => "" }
    self.learn_prompt_cache_key_rejection(body_text)
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
  let completion = decode_responses_response(resp_json)
  @posoco.ModelCallResult::{ completion, processed_messages: messages, }
}

///|
async fn KimiModelPort::chat_stream(
  self : KimiModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  cache_key : String?,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let body = build_responses_request(
    messages,
    tools,
    options,
    self.config.model,
    true,
    cache_key,
    reasoning_effort=Some(self.config.reasoning_effort),
  )
  let headers = build_headers(self.config)
  let client = @http.post_stream(responses_url(self.config), headers~) catch {
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
    match err_body {
      Some(text) => self.learn_prompt_cache_key_rejection(text)
      None => ()
    }
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
  let sse_state = @responses.SseStreamState::SseStreamState()
  let mut done = false
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
          let payload = trimmed["data:".length():].to_owned()
          let pl = payload.trim()
          if pl == "[DONE]" {
            done = true
          } else if pl.length() > 0 {
            done = @responses.process_responses_sse(
              provider="kimi",
              pl.to_owned(),
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
            provider="kimi",
            @responses.StreamTermination::CleanEof,
          ) {
          Some(err) => raise err
          None => done = true
        }
      }
    }
    // Throttled yield so the event loop can breathe; pause is a
    // cancellation point.
    let now = @async.now()
    if now - last_yield >= 16L {
      @async.pause() catch {
        _ => ()
      }
      last_yield = now
    }
  }
  client.close()
  match
    @responses.classify_stream_termination(
      provider="kimi",
      @responses.StreamTermination::ExplicitTerminal,
    ) {
    Some(err) => raise err
    None => ()
  }
  let completion = attach_kimi_stream_reasoning(
    @responses.responses_stream_completion(provider="kimi", acc),
    sse_state,
  )
  @posoco.ModelCallResult::{ completion, processed_messages: messages, }
}

///|
pub impl @posoco.ModelPort for KimiModelPort with fn provider_config(
  self : KimiModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=Some(0.85),
  )
}
