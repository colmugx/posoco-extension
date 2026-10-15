///|
/// Native+wasm+js: moonbitlang/async/http (`@http`) is unavailable on wasm-gc.
///
/// Anthropic Messages wire for models the gateway serves natively on
/// `/messages` (Claude family, qwen3.7/3.8 flash-plus tiers, MiniMax M3 and
/// Qwen3.8 Max on the Go plane). The request/response/SSE machinery comes
/// from `posoco-kit-messages`; this file owns the transport, the URL and
/// header conventions, and the reasoning-state translation:
///
/// - the picker's effort levels map onto `thinking` budget tokens (the
///   gateway normalizes per upstream, so level names are posoco vocabulary);
/// - `none` / `off` disable thinking, `on` (toggle-only models) enables it
///   on the default budget;
/// - images downgrade to explicit placeholders for models without declared
///   image input, never a silent drop.

///|
fn messages_url(config : OpenCodeZenConfig) -> String {
  config.base_url + config.endpoint_prefix + "/messages"
}

///|
/// Split leading system messages from the transcript. The Messages API takes
/// the system prompt as a top-level field, not a message role.
fn zen_split_system(
  messages : Array[@posoco.Message],
) -> (Array[@posoco.Content], Array[@posoco.Message]) {
  let system : Array[@posoco.Content] = []
  let rest : Array[@posoco.Message] = []
  for msg in messages {
    match msg {
      SystemMessage(content~) =>
        for block in content {
          system.push(block)
        }
      _ => rest.push(msg)
    }
  }
  (system, rest)
}

///|
/// Placeholder for an image the model cannot accept: a decoded-byte size
/// estimate so the model can gauge the attachment without seeing it.
fn zen_image_placeholder(media_type : String, data : String) -> String {
  let approx_kb = data.length() * 3 / 4096
  "[Attached " +
  media_type +
  ", ~" +
  approx_kb.to_string() +
  " KB, omitted: this model does not accept image input]"
}

///|
/// Image downgrade for wires without per-message content gating: images in
/// message content and tool outcomes become explicit text placeholders.
/// Text passes through untouched.
fn zen_shape_images(
  messages : Array[@posoco.Message],
  supports_images : Bool,
) -> Array[@posoco.Message] {
  if supports_images {
    return messages
  }
  messages.map(fn(msg) {
    match msg {
      SystemMessage(content~) =>
        SystemMessage(
          content=content.map(fn(block) {
            match block {
              Image(media_type~, data~) =>
                Text(zen_image_placeholder(media_type, data))
              text => text
            }
          }),
        )
      UserMessage(content~) =>
        UserMessage(
          content=content.map(fn(block) {
            match block {
              Image(media_type~, data~) =>
                Text(zen_image_placeholder(media_type, data))
              text => text
            }
          }),
        )
      AssistantMessage(..) => msg
      ToolMessage(call_id~, tool_name~, outcome~) =>
        ToolMessage(
          call_id~,
          tool_name~,
          outcome=match outcome {
            SuccessWithAttachments(content~, structured~, attachments~) => {
              let merged = StringBuilder()
              merged.write_string(content)
              for block in attachments {
                merged.write_string("\n")
                match block {
                  Image(media_type~, data~) =>
                    merged.write_string(zen_image_placeholder(media_type, data))
                  Text(text) => merged.write_string(text)
                }
              }
              SuccessWithAttachments(content=merged.to_string(), structured~, attachments=[])
            }
            other => other
          },
        )
    }
  })
}

///|
/// Translate the config's (thinking, effort) state onto the Messages wire.
/// `none` and `off` disable; a level maps to a budget; the bare `on` toggle
/// uses the default budget.
fn zen_messages_thinking(
  config : OpenCodeZenConfig,
) -> @messages.ThinkingConfig? {
  if !config.thinking {
    return None
  }
  match config.reasoning_effort {
    Some("none") | Some("off") => None
    Some(level) =>
      Some(
        @messages.ThinkingConfig::Enabled(
          budget_tokens=Some(zen_messages_thinking_budget(level)),
        ),
      )
    None => Some(@messages.ThinkingConfig::Enabled(budget_tokens=Some(8192)))
  }
}

///|
/// Build the Messages request body.
fn build_messages_request(
  config : OpenCodeZenConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream~ : Bool = false,
) -> Json raise @posoco.ModelError {
  let shaped = zen_shape_images(
    @chatkit.fold_tool_attachments(messages, config.supports_images),
    config.supports_images,
  )
  let (system, transcript) = zen_split_system(shaped)
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
  let wire_tools : Array[Json] = tools.map(fn(tool) {
    @messages.tool_to_wire(tool~)
  })
  let extra : Array[(String, Json)] = if stream {
    [("stream", Json::boolean(true))]
  } else {
    []
  }
  let request_options = @messages.MessagesRequestOptions::MessagesRequestOptions(
    temperature=options.temperature,
    thinking=zen_messages_thinking(config),
    extra_top_level=extra,
  )
  @messages.encode_request(
    model=config.model,
    max_tokens=config.max_output_tokens,
    system=system_json,
    messages=wire_messages,
    tools=wire_tools,
    options=request_options,
  )
}

///|
async fn OpenCodeZenModelPort::chat_messages(
  self : OpenCodeZenModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  match stream {
    NoStream => {
      let body = build_messages_request(self.config, messages, tools, options)
      let (response, body_data) = @http.post(
        messages_url(self.config),
        body.stringify(),
        headers=build_messages_headers(self.config),
      ) catch {
        err =>
          raise @posoco.ModelError::Transport(
            "opencode-zen transport failure (stage=post): " + err.to_string(),
          )
      }
      let body_text = body_data.text() catch {
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "opencode-zen response parse failure (stage=decode_utf8, body_bytes=\{body_data.binary().length()})",
          )
      }
      if !is_zen_http_success(response.code) {
        match
          classify_zen_http_status(
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
            "opencode-zen response parse failure (stage=json, body_chars=\{body_text.length()})",
          )
      }
      let result = @messages.parse_response(provider="opencode-zen", resp_json)
      @posoco.ModelCallResult::{
        completion: result.completion,
        processed_messages: messages,
      }
    }
    Stream(on_chunk) => {
      let body = build_messages_request(
        self.config,
        messages,
        tools,
        options,
        stream=true,
      )
      let client = @http.post_stream(
        messages_url(self.config),
        headers=build_messages_headers(self.config),
      ) catch {
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
      let state = @messages.MessagesSseState::MessagesSseState()
      let decoder = @messages.SseDecoder::SseDecoder()
      let mut done = false
      let mut last_yield = @async.now()
      while !done {
        let line = client.read_until("\n") catch {
          err => {
            client.close()
            raise @posoco.ModelError::Transport(
              "opencode-zen transport failure (stage=read_stream): " +
              err.to_string(),
            )
          }
        }
        match line {
          Some(data) =>
            for event in decoder.push(data + "\n") {
              done = @messages.process_messages_event(
                provider="opencode-zen",
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
                provider="opencode-zen",
                @messages.StreamTermination::CleanEof,
              ) {
              Some(err) => raise err
              None => done = true
            }
          }
        }
        // Same yield discipline as the chat-completions loop: a buffered SSE
        // burst must not starve the host event loop, and the pause doubles
        // as the cancellation point.
        let now = @async.now()
        if now - last_yield >= 16L {
          @async.pause()
          last_yield = now
        }
      }
      client.close()
      match
        @messages.classify_stream_termination(
          provider="opencode-zen",
          @messages.StreamTermination::ExplicitTerminal,
        ) {
        Some(err) => raise err
        None => ()
      }
      let result = @messages.messages_stream_result(
        provider="opencode-zen",
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
