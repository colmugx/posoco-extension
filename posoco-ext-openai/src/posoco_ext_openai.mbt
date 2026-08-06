///|
/// posoco_ext_llm.mbt — OpenAI Responses API adapter for posoco.
///
/// Implements ModelPort::chat() and chat_streaming() using the Responses API.
/// chat_streaming uses SSE (Server-Sent Events) with StreamAccumulator.

///|
/// Configuration for the OpenAI Responses API adapter.
pub(all) struct OpenAIConfig {
  api_key : String
  model : String
  base_url : String // default: "https://api.openai.com/v1"
  organization : String?
  /// Required for ChatGPT/Codex subscription requests; absent for API-key
  /// OpenAI-compatible endpoints.
  account_id : String?
  /// Provider-declared reasoning effort selected by the model catalog.
  reasoning_effort : String?
}

///|
/// Create an OpenAIConfig with defaults.
pub fn OpenAIConfig::new(api_key : String, model : String) -> OpenAIConfig {
  {
    api_key,
    model,
    base_url: "https://api.openai.com/v1".to_string(),
    organization: None,
    account_id: None,
    reasoning_effort: None,
  }
}

///|
/// Create an OpenAI Responses configuration for a compatible endpoint.
///
/// The default constructor remains the canonical OpenAI endpoint. Hosts that
/// deliberately inject a compatible Responses provider can use this explicit
/// constructor without reaching into the configuration representation.
pub fn OpenAIConfig::with_base_url(
  api_key : String,
  model : String,
  base_url : String,
) -> OpenAIConfig {
  {
    api_key,
    model,
    base_url,
    organization: None,
    account_id: None,
    reasoning_effort: None,
  }
}

///|
/// Build the provider-owned Codex OAuth configuration. The OAuth endpoint is
/// selected here so hosts do not need to parse or remember provider URLs.
pub fn OpenAIConfig::from_codex_credential(
  credential : @oauth.Credential,
  model : String,
) -> OpenAIConfig {
  let config = OpenAIConfig::with_base_url(
    credential.access_token,
    model,
    codex_oauth_api_base(),
  )
  { ..config, account_id: credential.metadata_value("account_id") }
}

///|
/// Return a copy configured with one server-declared reasoning effort.  The
/// catalog owns validation of the advertised values; this method only carries
/// the selected value into the provider request body.
pub fn OpenAIConfig::with_reasoning_effort(
  self : OpenAIConfig,
  effort : String,
) -> OpenAIConfig {
  { ..self, reasoning_effort: Some(effort) }
}

///|
/// OpenAI ModelPort adapter — implements posoco's ModelPort trait.
pub(all) struct OpenAIModelPort {
  config : OpenAIConfig
}

///|
pub fn OpenAIModelPort::new(config : OpenAIConfig) -> OpenAIModelPort {
  { config, }
}

///|
/// Redacted non-2xx body metadata. Keeping this as an ADT prevents the raw
/// provider body from crossing the HTTP-error formatting boundary.
priv enum OpenAIErrorBodySummary {
  BodyChars(Int)
  BodyBytesUtf8(Int)
  BodyBytesInvalidUtf8(Int)
  BodyReadFailed
  BodyUnavailable
}

///|
/// Pure non-2xx body classification. Callers pass only lengths and decode
/// success, so provider payloads cannot cross this boundary.
fn classify_openai_error_body(
  byte_length : Int,
  decoded_chars : Int?,
) -> OpenAIErrorBodySummary {
  match decoded_chars {
    Some(chars) => BodyChars(chars)
    None => BodyBytesInvalidUtf8(byte_length)
  }
}

///|
/// T07-B: drain a non-2xx response without exposing provider payloads.
async fn read_error_body_summary(
  client : @http.Client,
) -> OpenAIErrorBodySummary {
  let data = client.read_all() catch { _ => return BodyReadFailed }
  let byte_length = data.binary().length()
  let _ = data.text() catch { _ => return BodyBytesInvalidUtf8(byte_length) }
  BodyBytesUtf8(byte_length)
}

///|
/// Format an HTTP failure from already-redacted metadata. The response body is
/// deliberately not accepted by this function.
fn format_openai_http_error(
  stage : String,
  status : Int,
  body_summary : OpenAIErrorBodySummary,
) -> String {
  let summary = match body_summary {
    BodyChars(length) => "body_chars=\{length}, body_category=utf8"
    BodyBytesUtf8(length) => "body_bytes=\{length}, body_category=utf8"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
  "OpenAI HTTP error (stage=\{stage}, status=\{status}, \{summary})"
}

///|
fn is_openai_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// Pure HTTP-status classification shared by streaming and non-streaming
/// paths. All 2xx statuses continue through success-body parsing; every other
/// status retains its code and only redacted body metadata.
fn classify_openai_http_status(
  stage : String,
  status : Int,
  body_summary : OpenAIErrorBodySummary,
) -> @posoco.ModelError? {
  if is_openai_http_success(status) {
    None
  } else {
    Some(
      @posoco.ModelError::Transport(
        format_openai_http_error(stage, status, body_summary),
      ),
    )
  }
}

///|
/// Build the HTTP headers for OpenAI API requests.
fn build_headers(config : OpenAIConfig) -> Map[String, String] {
  let headers : Map[String, String] = {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
  match config.organization {
    Some(org) => headers.set("OpenAI-Organization", org)
    None => ()
  }
  match config.account_id {
    Some(account_id) => headers.set("chatgpt-account-id", account_id)
    None => ()
  }
  headers
}

///|
/// A Codex subscription endpoint rejects requests without the account header.
/// Validate before opening a client so a malformed persisted credential cannot
/// become an opaque provider 401.
fn validate_openai_config(
  config : OpenAIConfig,
) -> Unit raise @posoco.ModelError {
  if config.base_url == codex_oauth_api_base() {
    match config.account_id {
      Some(value) if value.length() > 0 => ()
      _ =>
        raise @posoco.ModelError::Transport(
          "Codex request requires chatgpt-account-id metadata",
        )
    }
  }
}

///|
/// Build the JSON request body for the Responses API.
fn build_request_body(
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  model : String,
  reasoning_effort : String?,
  stream? : Bool = false,
) -> Json {
  let input_items : Array[Json] = []
  for m in messages {
    for item in posoco_message_to_openai_items(m) {
      input_items.push(item)
    }
  }
  let fields : Array[(String, Json)] = [
    ("model", Json::string(model)),
    ("input", Json::array(input_items)),
  ]
  if stream {
    fields.push(("stream", Json::boolean(true)))
  }
  if !tools.is_empty() {
    let tool_defs = tools.map(fn(t) { posoco_tool_to_openai(t) })
    fields.push(("tools", Json::array(tool_defs)))
  }
  match reasoning_effort {
    Some(effort) => {
      // Codex parity: ask for the summary text AND the encrypted reasoning
      // payload. The encrypted_content is what makes replayed reasoning items
      // carry real state across turns (official reasoning guide); without it
      // the verbatim replay is a hollow shell.
      fields.push(
        (
          "reasoning",
          Json::object(
            Map::from_array([
              ("effort", Json::string(effort)),
              ("summary", Json::string("auto")),
            ]),
          ),
        ),
      )
      fields.push(
        ("include", Json::array([Json::string("reasoning.encrypted_content")])),
      )
    }
    None => ()
  }
  let final_fields = append_options(fields, options)
  Json::object(Map::from_array(final_fields))
}

///|
/// Append ChatOptions to request body fields.
fn append_options(
  fields : Array[(String, Json)],
  options : @posoco.ChatOptions,
) -> Array[(String, Json)] {
  let result : Array[(String, Json)] = []
  for f in fields {
    result.push(f)
  }
  match options.temperature {
    Some(t) => result.push(("temperature", Json::number(t)))
    None => ()
  }
  match options.max_output_tokens {
    Some(n) => result.push(("max_output_tokens", Json::number(n.to_double())))
    None => ()
  }
  result
}

///|
pub impl @posoco.ModelPort for OpenAIModelPort with fn chat(
  self : OpenAIModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  match stream {
    NoStream => self.chat_nonstream(messages, tools, options)
    Stream(on_chunk) => self.chat_stream(messages, tools, options, on_chunk)
  }
}

///|
async fn OpenAIModelPort::chat_stream(
  self : OpenAIModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  on_chunk : (Json) -> Unit,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  validate_openai_config(self.config)
  let body = build_request_body(
    messages,
    tools,
    options,
    self.config.model,
    self.config.reasoning_effort,
    stream=true,
  )
  let headers = build_headers(self.config)
  let client = @http.Client::Client(self.config.base_url, headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=create_client)",
      )
  }
  client.request(@http.RequestMethod::Post, "/responses") catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=send_request)",
      )
    }
  }
  client.write(body.stringify()) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=write_body)",
      )
    }
  }
  client.flush() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=flush)",
      )
    }
  }
  let response = client.end_request() catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=end_request)",
      )
    }
  }
  if !is_openai_http_success(response.code) {
    let err_summary = read_error_body_summary(client) catch {
      _ => BodyUnavailable
    }
    client.close()
    match
      classify_openai_http_status("http_status", response.code, err_summary) {
      Some(err) => raise err
      None => ()
    }
  }
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let reasoning_sink = ReasoningSink::{ items: [], summary: "" }
  let on_typed = fn(chunk : @posoco.StreamChunk) {
    acc.push(chunk)
    on_chunk(streamchunk_to_json(chunk))
  }
  let mut done = false
  while !done {
    let line = client.read_until("\n") catch {
      _ => {
        client.close()
        match classify_stream_termination(TransportFailure) {
          Some(err) => raise err
          None => None
        }
      }
    }
    match line {
      Some(data) => {
        let trimmed = data.trim()
        if trimmed.has_prefix("data:") {
          let payload = trimmed["data:".length():].to_owned()
          let pl = payload.trim()
          if pl == "[DONE]" {
            done = true
          } else if pl.length() > 0 {
            done = process_sse_event(
              pl.to_owned(),
              acc,
              on_typed,
              reasoning_sink~,
            )
          }
        }
      }
      None => {
        client.close()
        match classify_stream_termination(CleanEof) {
          Some(err) => raise err
          None => done = true
        }
      }
    }
  }
  client.close()
  match classify_stream_termination(ExplicitTerminal) {
    Some(err) => raise err
    None => ()
  }
  validate_stream_tool_calls(acc)
  let completion = attach_reasoning_items(acc.to_completion(), reasoning_sink)
  @posoco.ModelCallResult::{ completion, processed_messages: messages }
}

///|
/// Attach the reasoning items captured from the terminal `response.completed`
/// event to the accumulated completion, so later requests replay them
/// verbatim (official reasoning guide: pass back all reasoning items since
/// the last user message when manually managing state).
fn attach_reasoning_items(
  completion : @posoco.Completion,
  sink : ReasoningSink,
) -> @posoco.Completion {
  if sink.items.is_empty() {
    return completion
  }
  let content = match completion.message.reasoning {
    Some(r) => if r.content == "" { sink.summary } else { r.content }
    None => sink.summary
  }
  let reasoning = @posoco.Reasoning::{
    content,
    raw: Some(Json::array(sink.items)),
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
/// Shared POST helper for the Responses API family: builds the client, sends
/// the JSON body, classifies transport/HTTP failures, and parses the response
/// JSON. Used by chat (non-stream) and compact.
async fn openai_post_json(
  config : OpenAIConfig,
  path : String,
  body : Json,
) -> Json raise @posoco.ModelError {
  let headers = build_headers(config)
  let client = @http.Client::Client(config.base_url, headers~) catch {
    _ =>
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=create_client)",
      )
  }
  let response = client.post(path, body.stringify()) catch {
    _ => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=send_request)",
      )
    }
  }
  let body_data = client.read_all() catch {
    _ => {
      client.close()
      match
        classify_openai_http_status(
          "http_status",
          response.code,
          BodyReadFailed,
        ) {
        Some(err) => raise err
        None =>
          raise @posoco.ModelError::Transport(
            "OpenAI transport failure (stage=read_response)",
          )
      }
    }
  }
  client.close()
  if !is_openai_http_success(response.code) {
    let decoded_chars : Int? = Some(body_data.text().length()) catch {
      _ => None
    }
    match
      classify_openai_http_status(
        "http_status",
        response.code,
        classify_openai_error_body(body_data.binary().length(), decoded_chars),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=decode_utf8, body_bytes=\{body_data.binary().length()})",
      )
  }
  @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=json, body_chars=\{body_text.length()})",
      )
  }
}

///|
async fn OpenAIModelPort::chat_nonstream(
  self : OpenAIModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  validate_openai_config(self.config)
  let body = build_request_body(
    messages,
    tools,
    options,
    self.config.model,
    self.config.reasoning_effort,
  )
  let resp_json = openai_post_json(self.config, "/responses", body)
  let completion = parse_openai_response(resp_json)
  @posoco.ModelCallResult::{ completion, processed_messages: messages }
}

///|
/// Build the request body for the standalone compaction endpoint.
fn build_compact_request_body(
  messages : Array[@posoco.Message],
  model : String,
) -> Json {
  let input_items : Array[Json] = []
  for m in messages {
    for item in posoco_message_to_openai_items(m) {
      input_items.push(item)
    }
  }
  Json::object(
    Map::from_array([
      ("model", Json::string(model)),
      ("input", Json::array(input_items)),
    ]),
  )
}

///|
/// Validate a /responses/compact response envelope and decode its output
/// items into canonical messages.
fn parse_compact_response(
  resp_json : Json,
) -> Array[@posoco.Message] raise @posoco.ModelError {
  let output = match resp_json {
    Json::Object(map) => {
      match map.get("error") {
        Some(Json::Object(_)) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI compact terminal failure (stage=error, category=provider_error)",
          )
        _ => ()
      }
      match map.get("output") {
        Some(Json::Array(_) as out) => out
        Some(Json::Null) | None => Json::array([])
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI compact parse failure (stage=output, category=wrong_type)",
          )
      }
    }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI compact parse failure (stage=response, category=not_object)",
      )
  }
  openai_items_to_posoco_messages(output)
}

///|
/// ModelPort implementation — compact via the official standalone endpoint
/// (POST /responses/compact). Fully stateless and ZDR-friendly: we send the
/// full current window and the endpoint returns the canonical next context
/// window ("pass it into your next /responses call as-is — do not prune"),
/// which maps to Replace semantics. The opaque compaction item rides
/// Reasoning.raw and replays verbatim on subsequent chat calls.
pub impl @posoco.ModelPort for OpenAIModelPort with fn compact(
  self : OpenAIModelPort,
  messages : Array[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  validate_openai_config(self.config)
  let body = build_compact_request_body(messages, self.config.model)
  let resp_json = openai_post_json(self.config, "/responses/compact", body)
  let compacted = parse_compact_response(resp_json)
  @posoco.CompactResult::{
    compacted_messages: compacted,
    mode: @posoco.CompactMode::Replace,
  }
}

///|
pub impl @posoco.ModelPort for OpenAIModelPort with fn provider_config(
  _self : OpenAIModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}
