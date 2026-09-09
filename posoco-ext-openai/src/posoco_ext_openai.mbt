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
  /// Context capacity reported by Codex model discovery, in tokens. `None`
  /// = unknown (API-key discovery reports no window); auto-compact stays
  /// off rather than guessing.
  context_window : Int?
}

///|
/// Create an OpenAIConfig with defaults.
pub fn OpenAIConfig::OpenAIConfig(
  api_key : String,
  model : String,
) -> OpenAIConfig {
  {
    api_key,
    model,
    base_url: "https://api.openai.com/v1".to_string(),
    organization: None,
    account_id: None,
    reasoning_effort: None,
    context_window: None,
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
    context_window: None,
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
  { ..config, account_id: credential.metadata_value("account_id"), }
}

///|
/// Return a copy configured with one server-declared reasoning effort.  The
/// catalog owns validation of the advertised values; this method only carries
/// the selected value into the provider request body.
pub fn OpenAIConfig::with_reasoning_effort(
  self : OpenAIConfig,
  effort : String,
) -> OpenAIConfig {
  { ..self, reasoning_effort: Some(effort), }
}

///|
/// OpenAI ModelPort adapter — implements posoco's ModelPort trait.
pub(all) struct OpenAIModelPort {
  config : OpenAIConfig
  /// Captures Codex quota headers from chat responses when present. `None`
  /// on API-key endpoints and hosts that do not consume quota readings.
  quota_tracker : CodexQuotaTracker?
}

///|
pub fn OpenAIModelPort::OpenAIModelPort(
  config : OpenAIConfig,
  quota_tracker? : CodexQuotaTracker? = None,
) -> OpenAIModelPort {
  { config, quota_tracker, }
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
/// Drain a non-2xx response without exposing provider payloads.
/// Also returns the recovered UTF-8 text (in-process only) so the quota
/// classifier can read a stated reset time; the text is `None` when the
/// read failed or the body was not decodable.
async fn read_error_body_summary(
  client : @http.Client,
) -> (OpenAIErrorBodySummary, String?) {
  let data = client.read_all() catch { _ => return (BodyReadFailed, None) }
  let byte_length = data.binary().length()
  let text = data.text() catch {
    _ => return (BodyBytesInvalidUtf8(byte_length), None)
  }
  (BodyBytesUtf8(byte_length), Some(text))
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
/// Transport error for a cancelled wait. The `category=cancelled` marker is
/// the classification carrier: the ModelError raise type cannot carry the
/// coroutine cancellation itself (checked raise types), so downstream
/// consumers classify on this stable token instead of matching provider text.
fn openai_cancelled_transport(stage : String) -> @posoco.ModelError {
  @posoco.ModelError::Transport(
    "OpenAI transport failure (stage=\{stage}, category=cancelled)",
  )
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
/// 429 is a quota verdict, not a plain transport failure: every 429 becomes
/// the typed `RateLimited` — even with an empty or undecodable body (the
/// RateLimitGuard's probe backoff is the designed handler) — so the guard
/// can record the verdict and schedule resume. Any other status returns
/// None and keeps the generic HTTP-status path.
fn openai_quota_verdict(
  status : Int,
  body_text : String?,
  retry_after : String?,
  now_ms~ : Int64,
) -> @posoco.ModelError? {
  if status != 429 {
    return None
  }
  @chatkit.classify_chat_completions_http_error(
    status,
    match body_text {
      Some(text) => text
      None => ""
    },
    retry_after_header=retry_after,
    now_ms~,
  )
}

///|
/// Build the HTTP headers for OpenAI API requests. Every request carries a
/// posoco User-Agent; the Codex subscription endpoint additionally receives
/// the official protocol header shape (`compact` adds the installation id).
fn build_headers(
  config : OpenAIConfig,
  session_id : String?,
  stream : Bool,
  compact : Bool,
) -> @http.Headers {
  let headers : @http.Headers = {
    "Authorization": "Bearer \{config.api_key}",
    "Content-Type": "application/json",
  }
  headers.set("User-Agent", identity_user_agent_now())
  match config.organization {
    Some(org) => headers.set("OpenAI-Organization", org)
    None => ()
  }
  match config.account_id {
    Some(account_id) => headers.set("chatgpt-account-id", account_id)
    None => ()
  }
  if config.base_url == codex_oauth_api_base() {
    let sid = match session_id {
      Some(id) => id
      None => identity_fallback_session_id()
    }
    for key, value in codex_protocol_headers(sid, stream) {
      headers[@http.CaseInsensitiveString(key)] = value
    }
    if compact {
      headers.set("x-codex-installation-id", identity_installation_id())
    }
  }
  headers
}

///|
/// Split a base URL into the client origin and the endpoint path prefix.
/// `@http.Client::Client` only accepts `scheme://host[:port]` — any path makes
/// it raise `InvalidFormat` at stage=create_client — while its request paths
/// are host-relative. So `https://api.openai.com/v1` connects to
/// `https://api.openai.com` and prefixes every endpoint path with `/v1`. A
/// trailing slash is not part of the prefix; a bare host yields an empty one.
fn split_openai_base_url(
  base_url : String,
) -> (String, String) raise @posoco.ModelError {
  guard base_url.find("://") is Some(scheme_len) else {
    raise @posoco.ModelError::Transport(
      "OpenAI base_url must be scheme://host[:port][/prefix]",
    )
  }
  let host_start = scheme_len + 3
  let rest : StringView = base_url[host_start:]
  match rest.find("/") {
    Some(i) => {
      let origin = base_url[:host_start + i].to_owned()
      let prefix : StringView = rest[i:]
      if prefix == "/" {
        (origin, "")
      } else if prefix.has_suffix("/") {
        (origin, prefix[:prefix.length() - 1].to_owned())
      } else {
        (origin, prefix.to_owned())
      }
    }
    None => (base_url, "")
  }
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
    for item in @responses.message_to_responses_items(m) {
      input_items.push(item)
    }
  }
  let fields : Array[(String, Json)] = [
    ("model", Json::string(model)),
    ("input", Json::array(input_items)),
    // Codex parity: run stateless (ZDR-friendly). The server keeps no
    // response state; the full window is replayed as input on every call,
    // with encrypted reasoning / compaction items carrying the model state.
    ("store", Json::boolean(false)),
  ]
  if stream {
    fields.push(("stream", Json::boolean(true)))
  }
  if !tools.is_empty() {
    let tool_defs = tools.map(fn(t) { @responses.tool_to_responses_wire(t) })
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
  let options : @posoco.ChatOptions = match reasoning_effort {
    // Reasoning-model requests (Codex / gpt-5 family) reject temperature with
    // 400 "Unsupported parameter"; hosts tune temperature=0.0 by default, so
    // strip it instead of failing the turn.
    Some(_) => { ..options, temperature: None, }
    None => options
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
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let messages_owned = messages.to_owned()
  let session_id = scope.session_id.to_string()
  match stream {
    NoStream => self.chat_nonstream(session_id, messages_owned, tools, options)
    Stream(on_chunk) =>
      self.chat_stream(session_id, messages_owned, tools, options, on_chunk)
  }
}

///|
async fn OpenAIModelPort::chat_stream(
  self : OpenAIModelPort,
  session_id : String,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  on_chunk : (@posoco.StreamChunk) -> Unit,
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
  let headers = build_headers(self.config, Some(session_id), true, false)
  let (origin, path_prefix) = split_openai_base_url(self.config.base_url)
  let client = @http.Client::Client(origin, headers~) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=create_client): " + err.to_string(),
      )
  }
  client.request(@http.RequestMethod::Post, path_prefix + "/responses") catch {
    err => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=send_request): " + err.to_string(),
      )
    }
  }
  client.write(body.stringify()) catch {
    err => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=write_body): " + err.to_string(),
      )
    }
  }
  client.flush() catch {
    err => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=flush): " + err.to_string(),
      )
    }
  }
  let response = client.end_request() catch {
    err => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=end_request): " + err.to_string(),
      )
    }
  }
  // Capture before the status branch: an exhausted 429 still states the
  // authoritative percentages and reset times.
  match self.quota_tracker {
    Some(tracker) => tracker.capture(response.headers)
    None => ()
  }
  if !is_openai_http_success(response.code) {
    let (err_summary, body_text) = read_error_body_summary(client) catch {
      _ => (BodyUnavailable, None)
    }
    client.close()
    match
      openai_quota_verdict(
        response.code,
        body_text,
        response.headers.get("Retry-After"),
        now_ms=@async.now(),
      ) {
      Some(err) => raise err
      None => ()
    }
    match
      classify_openai_http_status("http_status", response.code, err_summary) {
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
        if @async.is_cancellation_error(err) {
          raise openai_cancelled_transport("read_stream")
        }
        raise @posoco.ModelError::Transport(
          "OpenAI transport failure (stage=read_stream): " + err.to_string(),
        )
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
            done = @responses.process_responses_sse(
              provider="OpenAI",
              pl.to_owned(),
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
            provider="OpenAI",
            @responses.StreamTermination::CleanEof,
          ) {
          Some(err) => raise err
          None => done = true
        }
      }
    }
    // A buffered SSE burst makes read_until complete without suspending,
    // so this loop can spin through the whole stream in one coroutine
    // chain and the host never dispatches stdin (ESC/interrupt). Yield at
    // most every 16ms so the event loop can breathe; the pause is also a
    // cancellation point, which is what makes abort responsive.
    let now = @async.now()
    if now - last_yield >= 16L {
      @async.pause() catch {
        err =>
          if @async.is_cancellation_error(err) {
            client.close()
            raise openai_cancelled_transport("read_stream")
          }
        // Non-cancellation pause failures ride over; the next read on a
        // torn-down client errors out of the loop.
      }
      last_yield = now
    }
  }
  client.close()
  match
    @responses.classify_stream_termination(
      provider="OpenAI",
      @responses.StreamTermination::ExplicitTerminal,
    ) {
    Some(err) => raise err
    None => ()
  }
  let completion = attach_reasoning_items_responses(
    openai_stream_completion(acc),
    sse_state,
  )
  @posoco.ModelCallResult::{ completion, processed_messages: messages, }
}

///|
/// Use the canonical accumulator projection while retaining the provider
/// boundary in parse diagnostics (shared implementation in the responses kit).
fn openai_stream_completion(
  acc : @posoco.StreamAccumulator,
) -> @posoco.Completion raise @posoco.ModelError {
  @responses.responses_stream_completion(provider="OpenAI", acc)
}

///|
/// Attach the reasoning items captured from output_item events to the
/// accumulated completion, so later requests replay them verbatim (official
/// reasoning guide: pass back all reasoning items since the last user
/// message when manually managing state).
fn attach_reasoning_items_responses(
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
/// Shared POST helper for the Responses API family: builds the client, sends
/// the JSON body, classifies transport/HTTP failures, and parses the response
/// JSON. Used by chat (non-stream) and compact.
async fn openai_post_json(
  config : OpenAIConfig,
  path : String,
  body : Json,
  session_id : String?,
  quota_tracker? : CodexQuotaTracker? = None,
) -> Json raise @posoco.ModelError {
  let compact = path == "/responses/compact"
  let headers = build_headers(config, session_id, false, compact)
  let (origin, path_prefix) = split_openai_base_url(config.base_url)
  let client = @http.Client::Client(origin, headers~) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=create_client): " + err.to_string(),
      )
  }
  let response = client.post(path_prefix + path, body.stringify()) catch {
    err => {
      client.close()
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=send_request): " + err.to_string(),
      )
    }
  }
  match quota_tracker {
    Some(tracker) => tracker.capture(response.headers)
    None => ()
  }
  let body_data = client.read_all() catch {
    _ => {
      client.close()
      match
        openai_quota_verdict(
          response.code,
          None,
          response.headers.get("Retry-After"),
          now_ms=@async.now(),
        ) {
        Some(err) => raise err
        None => ()
      }
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
    let body_text : String? = Some(body_data.text()) catch { _ => None }
    let decoded_chars : Int? = match body_text {
      Some(text) => Some(text.length())
      None => None
    }
    match
      openai_quota_verdict(
        response.code,
        body_text,
        response.headers.get("Retry-After"),
        now_ms=@async.now(),
      ) {
      Some(err) => raise err
      None => ()
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
  session_id : String,
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
  let resp_json = openai_post_json(
    self.config,
    "/responses",
    body,
    Some(session_id),
    quota_tracker=self.quota_tracker,
  )
  let completion = @responses.parse_responses_response(
    provider="OpenAI",
    resp_json,
  )
  @posoco.ModelCallResult::{ completion, processed_messages: messages, }
}

///|
/// Build the request body for the standalone compaction endpoint.
fn build_compact_request_body(
  messages : Array[@posoco.Message],
  model : String,
) -> Json {
  let input_items : Array[Json] = []
  for m in messages {
    for item in @responses.message_to_responses_items(m) {
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
        // Missing/null output is a protocol failure, not an empty window:
        // decoding it as [] would wipe the session and report success.
        Some(Json::Null) | None =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI compact parse failure (stage=output, category=missing_output)",
          )
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
fn validate_compact_window(
  request_messages : Array[@posoco.Message],
  compacted : Array[@posoco.Message],
) -> Unit raise @posoco.ModelError {
  if request_messages.length() > 0 && compacted.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "OpenAI compact parse failure (stage=output, category=empty_window)",
    )
  }
}

///|
/// Compact via the official standalone endpoint
/// (POST /responses/compact). Fully stateless and ZDR-friendly: we send the
/// full current window and the endpoint returns the canonical next context
/// window ("pass it into your next /responses call as-is — do not prune"),
/// which maps to Replace semantics. The opaque compaction item rides
/// Reasoning.raw and replays verbatim on subsequent chat calls.
pub impl @posoco.ModelPort for OpenAIModelPort with fn compact(
  self : OpenAIModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  validate_openai_config(self.config)
  let request_messages = messages.to_owned()
  let body = build_compact_request_body(request_messages, self.config.model)
  let resp_json = openai_post_json(
    self.config,
    "/responses/compact",
    body,
    Some(scope.session_id.to_string()),
    quota_tracker=self.quota_tracker,
  )
  let compacted = parse_compact_response(resp_json)
  validate_compact_window(request_messages, compacted)
  @posoco.CompactResult::{
    compacted_messages: compacted,
    mode: @posoco.CompactMode::Replace,
  }
}

///|
pub impl @posoco.ModelPort for OpenAIModelPort with fn provider_config(
  self : OpenAIModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=self.config.context_window,
  )
}
