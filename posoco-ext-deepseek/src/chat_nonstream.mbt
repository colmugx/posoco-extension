///|
/// Non-streaming chat execution for DeepSeekModelPort: one HTTP
/// request/decode round, plus the bounded reasoning-exhaustion recovery
/// orchestration around it.

///|
/// One non-stream HTTP round: request build, POST, HTTP-status
/// classification, and strict decoding of the completion.
async fn DeepSeekModelPort::post_chat_once(
  self : DeepSeekModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  thinking_json : Json,
  effort_str : String?,
) -> @posoco.Completion raise @posoco.ModelError {
  let body = build_chat_request(
    self.ctx,
    messages,
    tools,
    options,
    self.config.model,
    false,
    thinking_json,
    effort_str,
    self.config.supports_images,
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
        "DeepSeek response parse failure (stage=decode_utf8, category=invalid_utf8, body_bytes=\\{body_data.binary().length()})",
      )
  }
  let resp_json : Json = @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=json, category=malformed, body_chars=\\{body_text.length()})",
      )
  }
  decode_chat_response(resp_json)
}

///|
/// Non-streaming chat with bounded recovery. A retry happens only when the
/// provider stopped at length with an entirely non-actionable response: no
/// answer text and no tool calls, so no prior work has reached the host.
/// The single retry re-asks at low effort with thinking enabled.
async fn DeepSeekModelPort::chat_nonstream(
  self : DeepSeekModelPort,
  messages_owned : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  thinking_json : Json,
  effort_str : String?,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let mut retry = false
  let mut attempts = 0
  while attempts < 2 {
    let selected_effort = if retry { Some("low") } else { effort_str }
    let selected_thinking = if retry {
      enabled_thinking_json()
    } else {
      thinking_json
    }
    let completion = self.post_chat_once(
      messages_owned, tools, options, selected_thinking, selected_effort,
    )
    if self.config.recover_on_reasoning_exhaustion &&
      attempts == 0 &&
      deepseek_can_retry_reasoning_exhaustion(completion) {
      self.ctx.warn(
        source="posoco-ext-deepseek",
        code="deepseek.reasoning_exhaustion_recovery",
        message="Retrying nonstream reasoning-only length cutoff once at low effort",
      )
      attempts += 1
      retry = true
      continue
    }
    return @posoco.ModelCallResult::{
      completion,
      processed_messages: messages_owned,
    }
  }
  raise @posoco.ModelError::Transport(
    "DeepSeek recovery exhausted its bounded retry attempts",
  )
}
