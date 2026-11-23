///|
fn build_headers(config : ZaiConfig) -> @http.Headers {
  {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
    "Accept-Language": "en-US,en",
    "anthropic-version": "2023-06-01",
  }
}

///|
fn messages_url(config : ZaiConfig) -> String {
  config.base_url + config.endpoint_prefix + "/v1/messages"
}

///|
/// Placeholder for an image the model cannot accept. The size is the
/// decoded-byte estimate (base64 length × 3/4) so the model can gauge how
/// much was attached without seeing it.
fn image_placeholder(media_type : String, data : String) -> String {
  let approx_kb = data.length() * 3 / 4096
  "[Attached " +
  media_type +
  ", ~" +
  approx_kb.to_string() +
  " KB, omitted: this model does not accept image input]"
}

///|
/// Image blocks degrade to explicit placeholders for models without
/// documented image input; text passes through untouched.
fn downgrade_image_blocks(
  blocks : Array[@posoco.Content],
) -> Array[@posoco.Content] {
  blocks.map(fn(block) {
    match block {
      @posoco.Content::Image(media_type~, data~) =>
        @posoco.Content::Text(image_placeholder(media_type, data))
      text => text
    }
  })
}

///|
/// Tool attachments degrade to explicit placeholders appended to the tool
/// text for models without documented image input (never a silent drop).
fn downgrade_tool_outcome(outcome : @posoco.ToolOutcome) -> @posoco.ToolOutcome {
  match outcome {
    @posoco.ToolOutcome::SuccessWithAttachments(
      content~,
      structured~,
      attachments~,
    ) => {
      let merged = StringBuilder()
      merged.write_string(content)
      for block in attachments {
        merged.write_string("\n")
        match block {
          @posoco.Content::Image(media_type~, data~) =>
            merged.write_string(image_placeholder(media_type, data))
          @posoco.Content::Text(text) => merged.write_string(text)
        }
      }
      @posoco.ToolOutcome::SuccessWithAttachments(
        content=merged.to_string(),
        structured~,
        attachments=[],
      )
    }
    other => other
  }
}

///|
/// Pre-encode window shaping for models without documented image input:
/// user/system images and tool attachments become explicit placeholders.
/// Vision models pass through untouched (the kit encodes native blocks).
fn shape_for_model(
  messages : Array[@posoco.Message],
  model : String,
) -> Array[@posoco.Message] {
  if zai_supports_images(model) {
    return messages
  }
  messages.map(fn(msg) {
    match msg {
      @posoco.Message::SystemMessage(content~) =>
        @posoco.Message::SystemMessage(content=downgrade_image_blocks(content))
      @posoco.Message::UserMessage(content~) =>
        @posoco.Message::UserMessage(content=downgrade_image_blocks(content))
      @posoco.Message::ToolMessage(call_id~, tool_name~, outcome~) =>
        @posoco.Message::ToolMessage(
          call_id~,
          tool_name~,
          outcome=downgrade_tool_outcome(outcome),
        )
      assistant => assistant
    }
  })
}

///|
/// All system content lifts to the top-level `system` field (in order); the
/// transcript itself never carries a system role in the Messages dialect.
fn split_system(
  messages : Array[@posoco.Message],
) -> (Array[@posoco.Content], Array[@posoco.Message]) {
  let system : Array[@posoco.Content] = []
  let transcript : Array[@posoco.Message] = []
  for msg in messages {
    match msg {
      @posoco.Message::SystemMessage(content~) =>
        for block in content {
          system.push(block)
        }
      other => transcript.push(other)
    }
  }
  (system, transcript)
}

///|
/// Uniform GLM-on-Messages posture: thinking is always enabled without a
/// budget (the endpoint scales thinking through its own effort control) and
/// the effort rides as the platform's top-level `reasoning_effort` field.
/// `stream` is the protocol's top-level SSE switch — streaming requests MUST
/// set it or the endpoint answers with one buffered JSON object, and
/// non-streaming requests MUST NOT (a buffered `stream: true` call is a
/// protocol violation).
fn build_request_options(
  config : ZaiConfig,
  options : @posoco.ChatOptions,
  stream~ : Bool = false,
) -> @messages.MessagesRequestOptions raise @posoco.ModelError {
  let temperature : Double? = match options.temperature {
    Some(t) =>
      if t > 1.0 {
        raise @posoco.ModelError::RequestBuild(
          "zai request build failure (stage=temperature, category=range): messages temperature must be within [0, 1]",
        )
      } else {
        Some(t)
      }
    None => None
  }
  let extra : Array[(String, Json)] = [
    ("reasoning_effort", Json::string(config.reasoning_effort)),
  ]
  if stream {
    extra.push(("stream", Json::boolean(true)))
  }
  @messages.MessagesRequestOptions::MessagesRequestOptions(
    temperature~,
    thinking=Some(@messages.ThinkingConfig::Enabled(budget_tokens=None)),
    extra_top_level=extra,
  )
}

///|
fn build_messages_request(
  config : ZaiConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream~ : Bool = false,
) -> Json raise @posoco.ModelError {
  let (system, transcript) = split_system(
    shape_for_model(messages, config.model),
  )
  let system_json : Json? = if system.is_empty() {
    None
  } else {
    Some(@messages.system_to_wire(content=system))
  }
  let wire_messages : Array[Json] = []
  for msg in transcript {
    for block in @messages.message_to_wire(msg) {
      wire_messages.push(block)
    }
  }
  let wire_tools : Array[Json] = tools.map(tool => @messages.tool_to_wire(tool~))
  let max_tokens = match options.max_output_tokens {
    Some(n) => n
    None => config.max_output_tokens
  }
  @messages.encode_request(
    model=config.model,
    max_tokens~,
    system=system_json,
    messages=wire_messages,
    tools=wire_tools,
    options=build_request_options(config, options, stream~),
  )
}

///|
/// Connection-level failures before any response byte arrives are safe to
/// re-dial: the provider either never saw the request or dropped it without
/// a verdict, so a bounded retry cannot duplicate a streamed answer.
const ZAI_TRANSPORT_MAX_ATTEMPTS : Int32 = 3

///|
fn zai_transport_retry_delay_ms(attempt : Int32) -> Int32 {
  // Backoff before attempts 2 and 3: long enough for a flapping upstream to
  // recover, short enough that a dead endpoint still fails fast in the UI.
  if attempt == 2 {
    500
  } else {
    1000
  }
}

///|
priv enum ZaiDialOutcome {
  Opened(client~ : @http.ClientConnection, response~ : @http.ResponseHeader)
  Dropped(stage~ : String, detail~ : String)
}

///|
/// One dial attempt: post_stream + body write + head exchange. Any failure
/// here happens strictly before a response byte exists, so it is always
/// retryable. A dead client is closed before returning Dropped.
async fn zai_dial_stream_once(
  url : String,
  payload : BytesView,
  headers : @http.Headers,
) -> ZaiDialOutcome {
  let client = @http.post_stream(url, headers~)
  client.write(payload) catch {
    err => {
      client.close()
      return ZaiDialOutcome::Dropped(
        stage="write_body",
        detail=@debug.Repr(err).to_string(),
      )
    }
  }
  let response = client.end_request() catch {
    err => {
      client.close()
      return ZaiDialOutcome::Dropped(
        stage="end_request",
        detail=@debug.Repr(err).to_string(),
      )
    }
  }
  ZaiDialOutcome::Opened(client~, response~)
}

///|
async fn zai_open_stream_with_retry(
  url : String,
  payload : BytesView,
  headers : @http.Headers,
) -> (@http.ClientConnection, @http.ResponseHeader) raise @posoco.ModelError {
  let mut attempts = 0
  let mut opened : (@http.ClientConnection, @http.ResponseHeader)? = None
  while opened is None {
    attempts += 1
    if attempts > 1 {
      @async.sleep(zai_transport_retry_delay_ms(attempts))
    }
    let dial = zai_dial_stream_once(url, payload, headers) catch {
      err =>
        ZaiDialOutcome::Dropped(
          stage="dial",
          detail=@debug.Repr(err).to_string(),
        )
    }
    match dial {
      Opened(client~, response~) => opened = Some((client, response))
      Dropped(stage~, detail~) =>
        if attempts >= ZAI_TRANSPORT_MAX_ATTEMPTS {
          raise @posoco.ModelError::Transport(
            "zai transport failure (stage=\{stage}, attempts=\{attempts}): \{detail}",
          )
        }
    }
  }
  match opened {
    Some(pair) => pair
    None => abort("zai transport retry loop exited without a verdict")
  }
}

///|
/// One non-streaming dial attempt. `None` means the connection died before
/// any verdict existed, which is always safe to re-dial.
async fn zai_post_binary_once(
  url : String,
  payload : BytesView,
  headers : @http.Headers,
) -> (@http.ResponseHeader, @http.MessageBody)? {
  let reply = @http.post_binary(url, payload, headers~) catch {
    _ => return None
  }
  Some(reply)
}

///|
pub impl @posoco.ModelPort for ZaiModelPort with fn chat(
  self : ZaiModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let messages_owned = messages.to_owned()
  let streaming = stream is Stream(_)
  let body = build_messages_request(
    self.config,
    messages_owned,
    tools,
    options,
    stream=streaming,
  )
  match stream {
    NoStream => {
      // Same pre-verdict retry rule as the streaming path: a failure here
      // happens before any response exists, so a re-dial cannot duplicate
      // an answer the caller received.
      let mut attempts = 0
      let mut delivered : (@http.ResponseHeader, @http.MessageBody)? = None
      while delivered is None {
        attempts += 1
        if attempts > 1 {
          @async.sleep(zai_transport_retry_delay_ms(attempts))
        }
        let attempt = zai_post_binary_once(
          messages_url(self.config),
          @utf8.encode(body.stringify())[:],
          build_headers(self.config),
        ) catch {
          _ => None
        }
        match attempt {
          Some(reply) => delivered = Some(reply)
          None =>
            if attempts >= ZAI_TRANSPORT_MAX_ATTEMPTS {
              raise @posoco.ModelError::Transport(
                "zai transport failure (stage=post, attempts=\{attempts}): connection dropped before a verdict",
              )
            }
        }
      }
      let (response, body_bytes) = match delivered {
        Some(pair) => pair
        None => abort("zai transport retry loop exited without a verdict")
      }
      let body_text = @utf8.decode(body_bytes.binary()) catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "zai response parse failure (stage=decode_utf8, body_bytes=\{body_bytes.binary().length()})",
          )
      }
      if !is_zai_http_success(response.code) {
        match
          classify_zai_http_error(
            "chat.http_status",
            response.code,
            body_text,
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let resp_json : Json = @json.parse(body_text) catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "zai response parse failure (stage=json, body_chars=\{body_text.length()})",
          )
      }
      let result = @messages.parse_response(provider="zai", resp_json)
      @posoco.ModelCallResult::{
        completion: result.completion,
        processed_messages: messages_owned,
      }
    }
    Stream(on_chunk) => {
      let (client, response) = zai_open_stream_with_retry(
        messages_url(self.config),
        @utf8.encode(body.stringify())[:],
        build_headers(self.config),
      )
      if !is_zai_http_success(response.code) {
        let err_body = read_error_body_text(client) catch { _ => None }
        match
          classify_zai_http_error(
            "chat_stream.http_status",
            response.code,
            match err_body {
              Some(text) => text
              None => ""
            },
            now_ms=@async.now(),
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let acc = @posoco.StreamAccumulator::StreamAccumulator()
      let state = @messages.MessagesSseState::MessagesSseState()
      let decoder = @messages.SseDecoder::SseDecoder()
      let mut done = false
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until(b"\n") catch {
          err =>
            raise @posoco.ModelError::Transport(
              "zai transport failure (stage=read_stream): " +
              @debug.Repr(err).to_string(),
            )
        }
        match line {
          Some(data) => {
            let chunk = @utf8.decode(data) catch {
              _ =>
                raise @posoco.ModelError::ResponseParse(
                  "zai SSE chunk decode failure (stage=decode_utf8)",
                )
            }
            for event in decoder.push(chunk + "\n") {
              done = @messages.process_messages_event(
                provider="zai",
                event_name=event.name,
                data=event.data,
                acc~,
                on_chunk~,
                state~,
              )
            }
          }
          None =>
            raise @posoco.ModelError::ResponseParse(
              "zai SSE truncated (stage=eof, terminal_marker=missing)",
            )
        }
        // Yield at most every 16ms so the event loop can breathe during a
        // buffered SSE burst; task cancellation also lands on this pause.
        let now = @async.now()
        if now - last_yield >= 16L {
          @async.pause()
          last_yield = now
        }
      }
      let result = @messages.messages_stream_result(
        provider="zai",
        acc~,
        state~,
      )
      @posoco.ModelCallResult::{
        completion: result.completion,
        processed_messages: messages_owned,
      }
    }
  }
}

///|
pub extend ZaiModelPort with @posoco.ModelPort::{provider_config, chat, compact}

///|
pub impl @posoco.ModelPort for ZaiModelPort with fn provider_config(
  self : ZaiModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=zai_thinking_efforts(),
    context_window=self.config.context_window,
    compact_threshold=None,
  )
}
