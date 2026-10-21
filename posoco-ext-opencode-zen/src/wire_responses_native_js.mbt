///|
/// Native+wasm+js: moonbitlang/async/http (`@http`) is unavailable on wasm-gc.
///
/// OpenAI Responses wire for models the gateway serves on `/responses`
/// (GPT, Grok, Muse families). Encoding and SSE parsing come from
/// `posoco-kit-responses`; this file owns the transport, URL, and the
/// request shape:
///
/// - base-instruction system items lift into the top-level `instructions`
///   field, tools into `tools` — each only when non-empty;
/// - the request runs stateless (`store:false`), replaying the full window
///   as input on every call, with reasoning items riding the transcript;
/// - a selected effort level becomes `reasoning.effort` (+ encrypted_content
///   inclusion, Codex parity); `none`/`off`/`on` send no reasoning surface;
/// - reasoning-capable requests drop temperature (the upstream rejects it).

///|
fn responses_url(config : OpenCodeZenConfig) -> String {
  config.base_url + config.endpoint_prefix + "/responses"
}

///|
/// Build the Responses request body.
fn build_responses_request(
  config : OpenCodeZenConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream~ : Bool = false,
) -> Json raise @posoco.ModelError {
  let shaped = zen_shape_images(
    @responses.fold_tool_attachments(messages, config.supports_images),
    config.supports_images,
  )
  let input : Array[Json] = []
  for msg in shaped {
    for item in @responses.message_to_responses_items(msg) {
      input.push(item)
    }
  }
  let history : Array[Json] = []
  let instructions : Array[String] = []
  for item in input {
    match item {
      Json::Object(fields) =>
        if fields.get("role") == Some(Json::string("system")) {
          instructions.push(
            @responses.message_item_text(provider="opencode-zen", fields),
          )
        } else {
          history.push(item)
        }
      _ => history.push(item)
    }
  }
  let effort : String? = match (config.thinking, config.reasoning_effort) {
    (true, Some(level)) =>
      if level == "none" || level == "off" {
        None
      } else {
        Some(level)
      }
    _ => None
  }
  let fields : Array[(String, Json)] = [
    ("model", Json::string(config.model)),
    ("input", Json::array(history)),
    ("store", Json::boolean(false)),
  ]
  if stream {
    fields.push(("stream", Json::boolean(true)))
  }
  let joined = instructions.join("\n\n")
  if joined.length() > 0 {
    fields.push(("instructions", Json::string(joined)))
  }
  if tools.length() > 0 {
    fields.push(
      (
        "tools",
        Json::array(tools.map(fn(t) { @responses.tool_to_responses_wire(t) })),
      ),
    )
  }
  let effective_options = match effort {
    Some(level) => {
      fields.push(
        (
          "reasoning",
          Json::object(
            Map::from_array([
              ("effort", Json::string(level)),
              ("summary", Json::string("auto")),
            ]),
          ),
        ),
      )
      fields.push(
        ("include", Json::array([Json::string("reasoning.encrypted_content")])),
      )
      // Reasoning requests reject temperature with 400; hosts tune
      // temperature=0.0 by default, so strip it instead of failing the turn.
      { ..options, temperature: None, }
    }
    None => options
  }
  match effective_options.temperature {
    Some(t) => fields.push(("temperature", Json::number(t)))
    None => ()
  }
  match effective_options.max_output_tokens {
    Some(n) => fields.push(("max_output_tokens", Json::number(n.to_double())))
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
/// Attach the reasoning items captured from output_item events to the
/// accumulated completion so later requests replay them verbatim (the
/// official reasoning guide: pass back all reasoning items since the last
/// user message when manually managing state).
fn zen_attach_reasoning_items(
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
  let reasoning = @posoco.Reasoning::{
    content,
    raw: Some(Json::array(state.items)),
  }
  @posoco.Completion::Completion(
    content=completion.message.content,
    tool_calls=completion.message.tool_calls,
    reasoning=Some(reasoning),
    finish_reason=completion.message.finish_reason,
    usage=completion.usage,
  )
}

///|
async fn OpenCodeZenModelPort::chat_responses(
  self : OpenCodeZenModelPort,
  scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  match stream {
    NoStream => {
      let body = build_responses_request(self.config, messages, tools, options)
      let (response, body_data) = @http.post(
        responses_url(self.config),
        body.stringify(),
        headers=build_headers(self.config, scope),
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
      let completion = @responses.parse_responses_response(
        provider="opencode-zen",
        resp_json,
      )
      @posoco.ModelCallResult::{ completion, processed_messages: messages, }
    }
    Stream(on_chunk) => {
      let body = build_responses_request(
        self.config,
        messages,
        tools,
        options,
        stream=true,
      )
      let headers = build_headers(self.config, scope)
      let url = responses_url(self.config)
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
      let sse_state = @responses.SseStreamState::SseStreamState()
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
          Some(data) => {
            let trimmed = data.trim()
            if trimmed.has_prefix("data:") {
              let payload = trimmed[5:].trim().to_owned()
              if payload == "[DONE]" {
                done = true
              } else if payload.length() > 0 {
                done = @responses.process_responses_sse(
                  provider="opencode-zen",
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
                provider="opencode-zen",
                @responses.StreamTermination::CleanEof,
              ) {
              Some(err) => raise err
              None => done = true
            }
          }
        }
        // Same yield discipline as the other SSE loops: bounded pauses keep
        // the host event loop responsive and provide the cancellation point.
        let now = @async.now()
        if now - last_yield >= 16L {
          @async.pause()
          last_yield = now
        }
      }
      client.close()
      match
        @responses.classify_stream_termination(
          provider="opencode-zen",
          @responses.StreamTermination::ExplicitTerminal,
        ) {
        Some(err) => raise err
        None => ()
      }
      let completion = zen_attach_reasoning_items(
        @responses.responses_stream_completion(provider="opencode-zen", acc),
        sse_state,
      )
      @posoco.ModelCallResult::{ completion, processed_messages: messages, }
    }
  }
}
