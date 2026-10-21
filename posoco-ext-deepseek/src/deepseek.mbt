///|
fn build_headers(config : DeepSeekConfig) -> @http.Headers {
  {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
}

///|
fn chat_url(config : DeepSeekConfig) -> String {
  config.base_url + config.endpoint_prefix + "/chat/completions"
}

///|
/// The full FIM completions URL (beta variant): base_url + /beta + endpoint_prefix + /completions.
fn fim_url(config : DeepSeekConfig) -> String {
  let base = if config.base_url.has_suffix("/beta") {
    config.base_url
  } else {
    config.base_url + "/beta"
  }
  base + config.endpoint_prefix + "/completions"
}

///|
/// The full prefix-completion URL (beta variant): base_url + /beta + endpoint_prefix + /chat/completions.
fn prefix_url(config : DeepSeekConfig) -> String {
  let base = if config.base_url.has_suffix("/beta") {
    config.base_url
  } else {
    config.base_url + "/beta"
  }
  base + config.endpoint_prefix + "/chat/completions"
}

///|
/// V4.1 renderer maps seven advertised levels onto three prompt values.
/// Canonicalize only when the operator explicitly selected that profile;
/// unknown hosted API aliases retain their original effort strings.
fn deepseek_v41_canonical_effort(effort : String) -> String {
  match effort {
    "minimal" | "low" => "low"
    "medium" | "high" | "xhigh" => "high"
    "max" | "ultra" => "max"
    other => other
  }
}

///|
/// DeepSeek's provider-owned thinking config. An empty `reasoning_effort`
/// means thinking is switched off: the wire carries `{type: "disabled"}` and
/// no `reasoning_effort` field.
fn DeepSeekModelPort::default_thinking_config(
  self : DeepSeekModelPort,
) -> (Json, String?) {
  if self.config.reasoning_effort == "" {
    (Json::object({ "type": Json::string("disabled") }), None)
  } else {
    let effort = if self.config.prompt_profile == "v4.1" {
      deepseek_v41_canonical_effort(self.config.reasoning_effort)
    } else {
      self.config.reasoning_effort
    }
    (enabled_thinking_json(), Some(effort))
  }
}

///|
/// The public ModelPort chat entry: request-shape decisions (thinking
/// config, message materialization) plus mode dispatch. The HTTP loops live
/// in `chat_nonstream.mbt` and `chat_stream.mbt`.
pub impl @posoco.ModelPort for DeepSeekModelPort with fn chat(
  self : DeepSeekModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let (thinking_json, effort_str) = self.default_thinking_config()
  let messages_owned = messages.to_owned()
  match stream {
    NoStream =>
      DeepSeekModelPort::chat_nonstream(
        self, messages_owned, tools, options, thinking_json, effort_str,
      )
    Stream(on_chunk) =>
      DeepSeekModelPort::chat_stream(
        self, messages_owned, tools, options, thinking_json, effort_str, on_chunk,
      )
  }
}

///|
pub extend DeepSeekModelPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}

///|
pub impl @posoco.ModelPort for DeepSeekModelPort with fn provider_config(
  self : DeepSeekModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
    compact_threshold=Some(0.80),
  )
}
