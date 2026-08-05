///|
/// posoco_ext_openai-compatible — ModelPort implementation.
///
/// Implements @posoco.ModelPort for any standard OpenAI Chat Completions
/// endpoint. Uses @http.post / @http.post_stream against
/// base_url + endpoint_prefix + "/chat/completions".

///|
/// Build HTTP headers for OpenAI-compatible API requests.
fn build_headers(config : OpenAICompatibleConfig) -> Map[String, String] {
  {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
}

///|
/// The full chat completions URL: base_url + endpoint_prefix + /chat/completions.
fn chat_url(config : OpenAICompatibleConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
/// The OpenAI-compatible ModelPort implementation. Implements @posoco.ModelPort
/// for chat/chat_streaming; compact declines (no provider-side endpoint).
pub(all) struct OpenAICompatibleModelPort {
  config : OpenAICompatibleConfig
  /// Provider id this port is scoped to (e.g. "qwen"). Used only for catalog
  /// labeling; it never appears on the wire request.
  provider_id : String
}

///|
pub fn OpenAICompatibleModelPort::new(
  provider_id : String,
  config : OpenAICompatibleConfig,
) -> OpenAICompatibleModelPort {
  { provider_id, config }
}

///|
/// Serialize a StreamChunk to the Json chunk convention the host stream
/// callback decodes: `{kind: "text"|"reasoning", token: "..."}` for deltas.
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
/// ModelPort implementation — chat with optional streaming.
pub impl @posoco.ModelPort for OpenAICompatibleModelPort with fn chat(
  self : OpenAICompatibleModelPort,
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
        self.config.reasoning_effort,
      )
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
        _ =>
          raise @posoco.ModelError::Transport(
            "openai-compatible transport failure (stage=post)",
          )
      }
      if !is_oai_compat_http_success(response.code) {
        match
          classify_oai_compat_http_status(
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
        self.config.reasoning_effort,
      )
      let headers = build_headers(self.config)
      let url = chat_url(self.config)
      let client = @http.post_stream(url, headers~) catch {
        _ =>
          raise @posoco.ModelError::Transport(
            "openai-compatible transport failure (stage=post_stream)",
          )
      }
      client.write(body.stringify()) catch {
        _ => {
          client.close()
          raise @posoco.ModelError::Transport(
            "openai-compatible transport failure (stage=write_body)",
          )
        }
      }
      let response = client.end_request() catch {
        _ => {
          client.close()
          raise @posoco.ModelError::Transport(
            "openai-compatible transport failure (stage=end_request)",
          )
        }
      }
      if !is_oai_compat_http_success(response.code) {
        let err_summary = read_error_body_summary(client) catch {
          _ => BodyUnavailable
        }
        client.close()
        match
          classify_oai_compat_http_status(
            "chat_stream.http_status",
            response.code,
            err_summary,
          ) {
          Some(err) => raise err
          None => ()
        }
      }
      let acc = @posoco.StreamAccumulator::StreamAccumulator()
      let on_typed = fn(chunk : @posoco.StreamChunk) {
        on_chunk(streamchunk_to_json(chunk))
      }
      let mut done = false
      let mut data_buffer = ""
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
                data_buffer = payload
                done = process_oai_compat_sse(payload, acc, on_typed)
              }
            } else if trimmed == "" && data_buffer.length() > 0 {
              data_buffer = ""
            }
          }
          None => {
            client.close()
            match classify_oai_compat_stream_termination(CleanEof) {
              Some(err) => raise err
              None => done = true
            }
          }
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

///|
/// ModelPort implementation — compact. This generic adapter exposes no
/// dedicated compact endpoint; the modelport declines by raising ResponseParse
/// so the pump's compact safe-point reports a typed failure rather than
/// silently no-op'ing.
pub impl @posoco.ModelPort for OpenAICompatibleModelPort with fn compact(
  _self : OpenAICompatibleModelPort,
  _messages : Array[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "openai-compatible provider does not implement compact (no provider-side endpoint)",
  )
}

///|
/// ModelPort implementation — provider_config. The generic adapter declares no
/// provider-config fields (M3.7 pull-based config learning).
pub impl @posoco.ModelPort for OpenAICompatibleModelPort with fn provider_config(
  _self : OpenAICompatibleModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}
