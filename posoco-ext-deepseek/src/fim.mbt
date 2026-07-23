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
/// Pure decoder for the DeepSeek FIM wire response. Keeping the decoder free
/// of HTTP concerns makes every malformed response shape testable offline.
fn decode_fim_response(json : Json) -> String raise @posoco.ModelError {
  guard json is Object(root) else {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek response parse failure (stage=fim.response, category=not_object)",
    )
  }
  match root.get("error") {
    Some(Object(_)) =>
      raise @posoco.ModelError::Transport(
        "DeepSeek API error (stage=fim.response.error, category=structured)",
      )
    Some(_) =>
      raise @posoco.ModelError::Transport(
        "DeepSeek API error (stage=fim.response.error, category=wrong_type)",
      )
    None => ()
  }
  let choices = match root.get("choices") {
    Some(Array(choices)) => choices
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=fim.choices, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=fim.choices, category=missing)",
      )
  }
  if choices.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek response parse failure (stage=fim.choices, category=empty)",
    )
  }
  guard choices[0] is Object(choice) else {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek response parse failure (stage=fim.choice, category=not_object)",
    )
  }
  match choice.get("text") {
    Some(String(text)) => text
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=fim.choice.text, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=fim.choice.text, category=missing)",
      )
  }
}

///|
/// FIM completion: given code before and after the cursor, fill the middle.
///
/// Example:
/// ```moonbit nocheck
/// async fn fim_example(
///   port : DeepSeekModelPort,
/// ) -> String raise @posoco.ModelError {
///   port.fim_completion(
///     "def fib(a):\n  if a <= 1: return a\n  ",
///     Some("return fib(a-1) + fib(a-2)"),
///   )
/// }
/// ```
pub async fn DeepSeekModelPort::fim_completion(
  self : DeepSeekModelPort,
  prefix : String,
  suffix : String?,
  max_tokens? : Int = 128,
) -> String raise @posoco.ModelError {
  let body = build_fim_request_body(self.config, prefix, suffix, max_tokens)
  let headers = build_headers(self.config)
  let url = fim_url(self.config)
  let (response, resp_data) = @http.post(url, body.stringify(), headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=fim.post)",
      )
  }
  if !is_deepseek_http_success(response.code) {
    let byte_length = resp_data.binary().length()
    match
      classify_deepseek_http_status(
        "fim.http_status",
        response.code,
        BodyBytesUtf8(byte_length),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let resp_text = resp_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=fim.decode_utf8, category=invalid_utf8, body_bytes=\{resp_data.binary().length()})",
      )
  }
  let resp_json : Json = @json.parse(resp_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=fim.json, category=malformed, body_chars=\{resp_text.length()})",
      )
  }
  decode_fim_response(resp_json)
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
/// async fn prefix_example(
///   port : DeepSeekModelPort,
///   messages : Array[@posoco.Message],
/// ) -> String raise @posoco.ModelError {
///   port.chat_prefix_completion(messages, "```json\n", Some(["```"]))
/// }
/// ```
pub async fn DeepSeekModelPort::chat_prefix_completion(
  self : DeepSeekModelPort,
  messages : Array[@posoco.Message],
  prefix : String,
  stop : Array[String]?,
) -> String raise @posoco.ModelError {
  let body = build_prefix_request_body(self.config, messages, prefix, stop)
  let headers = build_headers(self.config)
  let url = prefix_url(self.config)
  let (response, resp_data) = @http.post(url, body.stringify(), headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=prefix.post)",
      )
  }
  if !is_deepseek_http_success(response.code) {
    let byte_length = resp_data.binary().length()
    match
      classify_deepseek_http_status(
        "prefix.http_status",
        response.code,
        BodyBytesUtf8(byte_length),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let resp_text = resp_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=prefix.decode_utf8, category=invalid_utf8, body_bytes=\{resp_data.binary().length()})",
      )
  }
  let resp_json : Json = @json.parse(resp_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=prefix.json, category=malformed, body_chars=\{resp_text.length()})",
      )
  }
  // Reuse decode_chat_response for the response (same format as /chat/completions)
  let model_response = decode_chat_response(resp_json)
  // Extract text content from the response message
  match model_response.message.content {
    [@posoco.Content::Text(t), ..] => t
    [] =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=prefix.content, category=missing)",
      )
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=prefix.content, category=wrong_type)",
      )
  }
}
