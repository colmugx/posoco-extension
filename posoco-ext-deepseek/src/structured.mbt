///|
/// Build an explicit V4.1 JSON-schema output request. The hosted API may
/// reject this format; it is opt-in and never silently used for normal chat.
/// The backend, not this text renderer, must enforce constrained decoding.
fn DeepSeekModelPort::ds_json_schema_body(
  self : DeepSeekModelPort,
  messages : Array[@posoco.Message],
  schema_name : String,
  schema : Json,
) -> Json raise @posoco.ModelError {
  if self.config.prompt_profile != "v4.1" {
    raise @posoco.ModelError::Transport(
      "DeepSeek JSON schema requires an explicit V4.1 prompt profile",
    )
  }
  if schema_name.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek JSON schema name must not be empty",
    )
  }
  guard schema is Object(_) else {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek JSON schema must be an object",
    )
  }
  let (thinking_json, effort_str) = self.default_thinking_config()
  let request = build_chat_request(
    self.ctx,
    messages,
    [],
    @posoco.ChatOptions::{ temperature: None, max_output_tokens: None, },
    self.config.model,
    false,
    thinking_json,
    effort_str,
    self.config.supports_images,
  )
  guard request is Object(body) else {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek JSON schema request must be an object",
    )
  }
  body["response_format"] = Json::object({
    "type": Json::string("json_schema"),
    "json_schema": Json::object({
      "name": Json::string(schema_name),
      "strict": Json::boolean(true),
      "schema": schema,
    }),
  })
  Json::object(body)
}

///|
/// Request explicitly structured output using a V4.1 JSON Schema. Unlike a
/// prefix prompt, this does not assume text instructions guarantee validity:
/// the returned content is parsed and must be a JSON object. No tool calls
/// are executed and malformed/unsupported responses remain errors.
pub async fn DeepSeekModelPort::json_schema_completion(
  self : DeepSeekModelPort,
  messages : Array[@posoco.Message],
  schema_name : String,
  schema : Json,
) -> Json raise @posoco.ModelError {
  let body = self.ds_json_schema_body(messages, schema_name, schema)
  let headers = build_headers(self.config)
  let (response, body_data) = @http.post(
    chat_url(self.config),
    body.stringify(),
    headers~,
  ) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "DeepSeek JSON schema transport failure: " + err.to_string(),
      )
  }
  if !is_deepseek_http_success(response.code) {
    match
      classify_deepseek_http_status(
        "json_schema.http_status",
        response.code,
        BodyBytesUtf8(body_data.binary().length()),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek JSON schema response invalid UTF-8",
      )
  }
  let payload : Json = @json.parse(text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek JSON schema response malformed",
      )
  }
  let completion = decode_chat_response(payload)
  if completion.tool_calls().length() > 0 {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek JSON schema returned tool calls",
    )
  }
  let content = ds_compact_summary_text(completion)
  let parsed : Json = @json.parse(content) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek JSON schema output is not valid JSON",
      )
  }
  guard parsed is Object(_) else {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek JSON schema output is not an object",
    )
  }
  parsed
}
