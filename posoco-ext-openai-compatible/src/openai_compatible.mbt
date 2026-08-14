///|
/// posoco_ext_openai-compatible — ModelPort implementation.
///
/// Implements @posoco.ModelPort for any standard OpenAI Chat Completions
/// endpoint. Uses @http.post / @http.post_stream against
/// base_url + endpoint_prefix + "/chat/completions".

///|
/// Build HTTP headers for OpenAI-compatible API requests. Provider-specific
/// adapters may supply a per-request header factory; its values are merged
/// first, then the adapter-owned Authorization and Content-Type headers are
/// enforced so an identity hook cannot accidentally replace authentication.
fn build_headers(
  config : OpenAICompatibleConfig,
  request_headers : (() -> Map[String, String])?,
) -> Map[String, String] {
  let headers : Map[String, String] = Map([])
  match request_headers {
    Some(factory) =>
      for key, value in factory() {
        headers[key] = value
      }
    None => ()
  }
  headers["Authorization"] = "Bearer \{config.api_key}"
  headers["Content-Type"] = "application/json"
  headers
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
  /// Optional provider-owned hook evaluated immediately before every HTTP
  /// request. This keeps gateway-specific routing/identity headers out of the
  /// generic OpenAI-compatible config while allowing adapters such as
  /// OpenCode Zen to provide fresh request metadata.
  request_headers : (() -> Map[String, String])?
}

///|
pub fn OpenAICompatibleModelPort::new(
  provider_id : String,
  config : OpenAICompatibleConfig,
  request_headers? : () -> Map[String, String],
) -> OpenAICompatibleModelPort {
  { provider_id, config, request_headers }
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
/// ModelPort implementation — chat lives in chat_native_js.mbt (it drives
/// moonbitlang/async/http, which is native+js only). compact and
/// provider_config below are pure and compile on every backend.

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
