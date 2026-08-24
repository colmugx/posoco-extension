///|
/// posoco_ext_openrouter — ModelPort implementation.
///
/// Implements @posoco.ModelPort for the OpenRouter /api/v1/chat/completions
/// endpoint (ApiKey auth only). The distinguishing feature is the
/// `include_reasoning` switch: responses carry `reasoning_details`, which the
/// adapter stores verbatim on `Reasoning.raw` and replays on later turns.

///|
/// Build HTTP headers for OpenRouter API requests: ApiKey bearer plus the
/// optional `HTTP-Referer` / `X-Title` attribution headers (rankings only,
/// never inference behavior).
fn build_headers(config : OpenRouterConfig) -> @http.Headers {
  let headers : @http.Headers = {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
  match config.http_referer {
    Some(referer) =>
      headers[@http.CaseInsensitiveString("HTTP-Referer")] = referer
    None => ()
  }
  match config.title {
    Some(title) => headers[@http.CaseInsensitiveString("X-Title")] = title
    None => ()
  }
  headers
}

///|
/// The full chat completions URL: base_url + /chat/completions.
fn chat_url(config : OpenRouterConfig) -> String {
  config.base_url + "/chat/completions"
}

///|
/// The OpenRouter ModelPort implementation. Implements @posoco.ModelPort for
/// chat/chat_streaming (chat_native_js.mbt) and a summarize-based compact
/// (compact_native_js.mbt); wasm keeps raising fallbacks in the
/// *_wasm_fallback.mbt files.
pub(all) struct OpenRouterModelPort {
  config : OpenRouterConfig
}

///|
pub fn OpenRouterModelPort::OpenRouterModelPort(
  config : OpenRouterConfig,
) -> OpenRouterModelPort {
  { config, }
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
    Usage(input_tokens~, output_tokens~, total_tokens~, ..) =>
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
/// ModelPort implementation — provider_config. Reasoning vocabulary stays
/// undeclared (the router learns levels from the slot, not from here); the
/// auto-compact metadata from settings IS reported so the Agent can build its
/// per-turn RunPolicy from the active model's own numbers.
pub impl @posoco.ModelPort for OpenRouterModelPort with fn provider_config(
  self : OpenRouterModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=self.config.compact_threshold,
  )
}
