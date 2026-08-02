///|
/// posoco_ext_kimi — ModelPort implementation.
///
/// Implements @posoco.ModelPort for kimi's /chat/completions endpoint.
/// Uses @http.post / @http.post_stream with the full endpoint URL.

///|
/// Build HTTP headers for kimi API requests.
fn build_headers(config : KimiConfig) -> Map[String, String] {
  {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
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
  messages : Array[@posoco.Message],
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
  match stream {
    NoStream => {
      let body = build_chat_request(
        self.ctx,
        messages,
        tools,
        safe_options,
        self.config.model,
        false,
        thinking_json,
        None, // cache_key — host passes session_id via call_options
        reasoning_effort_str~,
      )
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
        _ =>
          raise @posoco.ModelError::Transport(
            "kimi transport failure (stage=post)",
          )
      }
      if !is_kimi_http_success(response.code) {
        match
          classify_kimi_http_status(
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
      @posoco.ModelCallResult::{ completion, processed_messages: messages }
    }
    Stream(on_chunk) => {
      let body = build_chat_request(
        self.ctx,
        messages,
        tools,
        safe_options,
        self.config.model,
        true,
        thinking_json,
        None,
        reasoning_effort_str~,
      )
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let client = @http.post_stream(url, headers~) catch {
        _ =>
          raise @posoco.ModelError::Transport(
            "kimi transport failure (stage=post_stream)",
          )
      }
      client.write(body.stringify()) catch {
        _ => {
          client.close()
          raise @posoco.ModelError::Transport(
            "kimi transport failure (stage=write_body)",
          )
        }
      }
      let response = client.end_request() catch {
        _ => {
          client.close()
          raise @posoco.ModelError::Transport(
            "kimi transport failure (stage=end_request)",
          )
        }
      }
      if !is_kimi_http_success(response.code) {
        let err_summary = read_error_body_summary(client) catch {
          _ => BodyUnavailable
        }
        client.close()
        match
          classify_kimi_http_status(
            "chat_stream.http_status",
            response.code,
            err_summary,
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let acc = @posoco.StreamAccumulator::StreamAccumulator()
      // Bridge: forward each StreamChunk to the host as a Json chunk matching
      // the {kind, token} convention PortHostAdapter decodes. The accumulator
      // is owned by process_kimi_sse, which pushes every chunk exactly
      // once; pushing here too would double every text/reasoning delta.
      let on_typed = fn(chunk : @posoco.StreamChunk) {
        on_chunk(streamchunk_to_json(chunk))
      }
      let mut done = false
      let mut data_buffer = ""
      while !done {
        let line = client.read_until("\n") catch {
          _ => {
            client.close()
            match classify_kimi_stream_termination(TransportFailure) {
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
                data_buffer = payload
                done = process_kimi_sse(payload, acc, on_typed)
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
      }
      client.close()
      match classify_kimi_stream_termination(ExplicitTerminal) {
        Some(err) => raise err
        None => ()
      }
      validate_kimi_stream_tool_calls(acc)
      let completion = acc.to_completion()
      @posoco.ModelCallResult::{ completion, processed_messages: messages }
    }
  }
}

///|
/// Serialize a StreamChunk to the Json chunk convention PortHostAdapter
/// decodes: `{kind: "text"|"reasoning", token: "..."}` for deltas. Other
/// chunk kinds (ToolCallDelta/Usage/Finish) are forwarded as a structured
/// object so a host can inspect them, but the primary text/reasoning path
/// matches what agent_puppet's stream callback expects.
fn streamchunk_to_json(chunk : @posoco.StreamChunk) -> Json {
  match chunk {
    TextDelta(token~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("text")),
          ("token", Json::string(token)),
        ]),
      )
    ReasoningDelta(token~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("reasoning")),
          ("token", Json::string(token)),
        ]),
      )
    ToolCallDelta(index~, id~, name~, arguments_delta~) => {
      let m : Map[String, Json] = {
        "kind": Json::string("tool_call_delta"),
        "index": Json::number(index.to_double()),
      }
      match id {
        Some(s) => m["id"] = Json::string(s)
        None => ()
      }
      match name {
        Some(s) => m["name"] = Json::string(s)
        None => ()
      }
      match arguments_delta {
        Some(s) => m["arguments_delta"] = Json::string(s)
        None => ()
      }
      Json::object(m)
    }
    Usage(input_tokens~, output_tokens~, total_tokens~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("usage")),
          ("input_tokens", Json::number(input_tokens.to_double())),
          ("output_tokens", Json::number(output_tokens.to_double())),
          ("total_tokens", Json::number(total_tokens.to_double())),
        ]),
      )
    Finish(reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("finish")),
          ("reason", Json::string(reason)),
        ]),
      )
  }
}

///|
/// ModelPort implementation — compact. kimi has no dedicated compact
/// endpoint; the modelport declines by raising ResponseParse so the pump's
/// compact safe-point reports a typed failure rather than silently no-op'ing.
pub impl @posoco.ModelPort for KimiModelPort with fn compact(
  _self : KimiModelPort,
  _messages : Array[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "kimi does not implement compact (no provider-side endpoint)",
  )
}

///|
/// ModelPort implementation — provider_config. Declares which reasoning_effort
/// values this modelport accepts (M3.7 pull-based config learning).
pub impl @posoco.ModelPort for KimiModelPort with fn provider_config(
  _self : KimiModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}
