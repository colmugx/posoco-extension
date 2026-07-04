///|
/// DeepSeek-native FIM (Fill-In-the-Middle) completion.
///
/// Uses the /beta/completions endpoint with `prompt` + `suffix` parameters
/// (the SDK injects FIM tokens internally — no manual <｜fim_begin｜> needed).
/// Uses the configured model. Max completion: 4096 tokens.

///|
fn build_fim_request_body(
  config : DeepSeekConfig,
  prefix : String,
  suffix : String?,
  max_tokens : Int,
) -> Json {
  let body_map : Map[String, Json] = {
    "model": Json::string(config.model),
    "prompt": Json::string(prefix),
    "max_tokens": Json::number(max_tokens.to_double()),
  }
  match suffix {
    Some(s) => body_map["suffix"] = Json::string(s)
    None => ()
  }
  Json::object(body_map)
}

///|
fn build_prefix_request_body(
  config : DeepSeekConfig,
  messages : Array[@posoco.Message],
  prefix : String,
  stop : Array[String]?,
) -> Json {
  let msg_arr = messages.map(encode_message)
  let prefix_msg : Map[String, Json] = {
    "role": Json::string("assistant"),
    "content": Json::string(prefix),
    "prefix": Json::boolean(true),
  }
  msg_arr.push(Json::object(prefix_msg))
  let body_map : Map[String, Json] = {
    "model": Json::string(config.model),
    "messages": Json::array(msg_arr),
  }
  match stop {
    Some(s) => body_map["stop"] = Json::array(s.map(fn(x) { Json::string(x) }))
    None => ()
  }
  Json::object(body_map)
}

///|
/// FIM completion: given code before and after the cursor, fill the middle.
///
/// Example:
/// ```moonbit nocheck
/// let filled = port.fim_completion(
///   prefix="def fib(a):\n  if a <= 1: return a\n  ",
///   suffix="return fib(a-1) + fib(a-2)",
/// )
/// ```
pub async fn DeepSeekModelPort::fim_completion(
  self : DeepSeekModelPort,
  prefix : String,
  suffix : String?,
  max_tokens? : Int = 128,
) -> String raise @posoco.ModelError {
  let base = beta_base(self.config)
  let body = build_fim_request_body(self.config, prefix, suffix, max_tokens)
  let headers = build_headers(self.config)
  let client = @http.Client::Client(base, headers~) catch {
    e => raise @posoco.ModelError::Transport("FIM client failed: \{e}")
  }
  let response = client.post("/completions", body.stringify()) catch {
    e => {
      client.close()
      raise @posoco.ModelError::Transport("FIM request failed: \{e}")
    }
  }
  let resp_data = client.read_all() catch {
    e => {
      client.close()
      raise @posoco.ModelError::Transport("FIM read failed: \{e}")
    }
  }
  client.close()
  let resp_text = resp_data.text() catch {
    e => raise @posoco.ModelError::ResponseParse("FIM decode failed: \{e}")
  }
  raise_http_status("FIM", response.code, resp_text)
  let resp_json : Json = @json.parse(resp_text) catch {
    e => raise @posoco.ModelError::ResponseParse("FIM JSON error: \{e}")
  }
  // FIM response: { "choices": [{ "text": "..." }] }
  guard resp_json is Object(root) else {
    raise @posoco.ModelError::ResponseParse("FIM response not object")
  }
  match root.get("error") {
    Some(Object(e)) =>
      match e.get("message") {
        Some(String(m)) =>
          raise @posoco.ModelError::Transport("DeepSeek FIM error: " + m)
        _ => raise @posoco.ModelError::Transport("unknown FIM error")
      }
    _ => ()
  }
  guard root.get("choices") is Some(Array(choices)) else {
    raise @posoco.ModelError::ResponseParse("FIM missing choices")
  }
  if choices.length() == 0 {
    raise @posoco.ModelError::ResponseParse("FIM empty choices")
  }
  match choices[0] {
    Object(choice) =>
      match choice.get("text") {
        Some(String(text)) => text
        _ => raise @posoco.ModelError::ResponseParse("FIM missing text field")
      }
    _ => raise @posoco.ModelError::ResponseParse("FIM invalid choice")
  }
}

///|
/// DeepSeek-native chat prefix completion.
///
/// Uses /beta/chat/completions with messages[-1] having role=assistant and
/// prefix=True. The model continues from the assistant message's content.
/// Common use: force structured output (e.g. prefix="```json\n" + stop=["```"]).
///
/// Example:
/// ```moonbit nocheck
/// let json_str = port.chat_prefix_completion(
///   messages=[user_msg("output JSON")],
///   prefix="```json\n",
///   stop=["```"],
/// )
/// ```
pub async fn DeepSeekModelPort::chat_prefix_completion(
  self : DeepSeekModelPort,
  messages : Array[@posoco.Message],
  prefix : String,
  stop : Array[String]?,
) -> String raise @posoco.ModelError {
  let base = beta_base(self.config)
  let body = build_prefix_request_body(self.config, messages, prefix, stop)
  let headers = build_headers(self.config)
  let client = @http.Client::Client(base, headers~) catch {
    e => raise @posoco.ModelError::Transport("Prefix client failed: \{e}")
  }
  let response = client.post("/chat/completions", body.stringify()) catch {
    e => {
      client.close()
      raise @posoco.ModelError::Transport("Prefix request failed: \{e}")
    }
  }
  let resp_data = client.read_all() catch {
    e => {
      client.close()
      raise @posoco.ModelError::Transport("Prefix read failed: \{e}")
    }
  }
  client.close()
  let resp_text = resp_data.text() catch {
    e => raise @posoco.ModelError::ResponseParse("Prefix decode failed: \{e}")
  }
  raise_http_status("prefix", response.code, resp_text)
  let resp_json : Json = @json.parse(resp_text) catch {
    e => raise @posoco.ModelError::ResponseParse("Prefix JSON error: \{e}")
  }
  // Reuse decode_chat_response for the response (same format as /chat/completions)
  let response = decode_chat_response(resp_json)
  // Extract text content from the response message
  match response.message.content[0] {
    @posoco.Content::Text(t) => t
    _ => ""
  }
}
