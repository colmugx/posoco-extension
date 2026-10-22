///|
/// Streaming chat execution for DeepSeekModelPort: the streaming HTTP
/// lifecycle, line-by-line SSE consumption, reasoning protection checks, and
/// completion finalization. SSE payloads stay with `process_deepseek_sse`.

///|
async fn DeepSeekModelPort::chat_stream(
  self : DeepSeekModelPort,
  messages_owned : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  thinking_json : Json,
  effort_str : String?,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let body = build_chat_request(
    self.ctx,
    messages_owned,
    tools,
    options,
    self.config.model,
    true,
    thinking_json,
    effort_str,
    self.config.supports_images,
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
          "DeepSeek transport failure (stage=read_stream): " + err.to_string(),
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
            match self.config.policy().observe(acc, done~) {
              Some(@dk.ReasoningBreach::RepetitionDetected) => {
                self.ctx.warn(
                  source="posoco-ext-deepseek",
                  code="deepseek.reasoning_repetition_detected",
                  message="Repeated reasoning suffix detected; aborting stream",
                )
                client.close()
                raise @posoco.ModelError::Transport(
                  "DeepSeek stream reasoning repetition detected (stage=read_stream, category=reasoning_repetition)",
                )
              }
              Some(@dk.ReasoningBreach::BudgetExceeded) => {
                client.close()
                raise @posoco.ModelError::Transport(
                  "DeepSeek reasoning stream exceeded configured max_reasoning_chars (stage=read_stream, category=reasoning_budget_exceeded)",
                )
              }
              None => ()
            }
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
    // buffered SSE burst; task cancellation also lands on this pause.
    let now = @async.now()
    if now - last_yield >= 16L {
      @async.pause()
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
  @posoco.ModelCallResult::{ completion, processed_messages: messages_owned, }
}
