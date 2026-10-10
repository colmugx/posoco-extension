///|
/// Responses-over-WebSocket transport for the Codex subscription endpoint
/// (opt-in via `OpenAIConfig.websocket`). A per-session cached connection
/// carries `response.create` frames; when the new input extends the previous
/// input plus the previous response's output items element-for-element, only
/// the delta rides a `previous_response_id` continuation. Every other shape
/// resends the full body, and any transport failure permanently falls the
/// session back to the SSE path — the wire fallback is always the exact
/// pre-WebSocket behavior.

///|
/// One live WebSocket session: the cached transport plus the continuation
/// state that makes incremental requests decidable.
priv struct WsSession {
  transport : WsTransport
  /// The exact input array sent with the last request on this connection.
  mut last_input : Array[Json]
  /// The last request body minus `input`. Equality here is what makes a
  /// delta semantically safe: all non-input properties unchanged.
  mut last_body_rest : Json
  /// Response id of the last completed response (connection-scoped state).
  mut last_response_id : String
  /// Server-added output items in arrival order. The next request's input
  /// must extend `last_input ++ items` element-for-element before a delta is
  /// allowed.
  mut last_response_items : Array[Json]
  /// Unix ms of the last proven liveness: a successful send or an arrived
  /// frame. Stale entries are reconnected, never reused as-is.
  mut last_activity_at_ms : Int64
}

///|
/// A cached connection idle longer than this is presumed half-open (NAT/LB
/// entries expire silently; the socket still reads OPEN locally). The floor
/// of real-world idle windows (~60s NAT, ~100s edge tiers) sits well above
/// it, so a false "stale" costs one cheap handshake while a missed one costs
/// a hung turn.
const WS_REUSE_MAX_IDLE_MS : Int64 = 30_000

///|
fn codex_ws_reuse_usable(last_activity_at_ms : Int64, now_ms : Int64) -> Bool {
  now_ms - last_activity_at_ms <= WS_REUSE_MAX_IDLE_MS
}

///|
let codex_ws_sessions : Ref[Map[String, WsSession]] = Ref::{
  val: Map::from_array([]),
}

///|
/// Sessions whose WebSocket attempt failed; they stay on SSE for the process
/// lifetime (pi's per-session fallback semantics).
let codex_ws_fallback_sessions : Ref[Map[String, Bool]] = Ref::{
  val: Map::from_array([]),
}

///|
fn codex_ws_session_is_fallback(session_id : String) -> Bool {
  codex_ws_fallback_sessions.val.contains(session_id)
}

///|
fn codex_ws_mark_session_fallback(session_id : String) -> Unit {
  codex_ws_drop_session(session_id)
  codex_ws_fallback_sessions.val[session_id] = true
}

///|
fn codex_ws_drop_session(session_id : String) -> Unit {
  match codex_ws_sessions.val.get(session_id) {
    Some(session) => {
      session.transport.close()
      codex_ws_sessions.val.remove(session_id)
    }
    None => ()
  }
}

///|
/// Derive the WebSocket responses URL from the HTTP base URL
/// (`{base}/codex/responses` with the scheme swapped to ws/wss).
fn codex_ws_url(base_url : String) -> String {
  let mut end = base_url.length()
  while end > 0 && base_url[end - 1] == '/' {
    end -= 1
  }
  let core : String = base_url[:end].to_owned()
  let with_path : String = if core.has_suffix("/codex/responses") {
    core
  } else if core.has_suffix("/codex") {
    core + "/responses"
  } else {
    core + "/codex/responses"
  }
  if with_path.has_prefix("https://") {
    "wss://" + with_path["https://".length():].to_owned()
  } else if with_path.has_prefix("http://") {
    "ws://" + with_path["http://".length():].to_owned()
  } else {
    with_path
  }
}

///|
/// Handshake headers: the Codex protocol identity without the HTTP-only
/// fields, plus the Responses-over-WebSocket beta opt-in.
fn codex_ws_handshake_headers(
  config : OpenAIConfig,
  session_id : String,
) -> @http.Headers {
  let headers = build_headers(config, Some(session_id), true)
  headers.remove(@http.CaseInsensitiveString("Accept"))
  headers.remove(@http.CaseInsensitiveString("Content-Type"))
  headers[@http.CaseInsensitiveString("OpenAI-Beta")] = "responses_websockets=2026-02-06"
  headers
}

///|
/// The request body minus `input` — the part that must stay unchanged for a
/// delta to be semantically safe.
fn codex_ws_body_rest(body : Json) -> Json {
  match body {
    Json::Object(fields) => {
      let rest : Map[String, Json] = Map::from_array([])
      for key, value in fields {
        if key != "input" {
          rest[key] = value
        }
      }
      Json::object(rest)
    }
    _ => Json::object(Map::from_array([]))
  }
}

///|
/// Wrap a request body into the WS wire frame: every message the backend
/// accepts must declare `type: "response.create"`.
fn codex_ws_frame(sent : Json) -> Json {
  match sent {
    Json::Object(fields) => {
      let framed : Map[String, Json] = Map::from_array([
        ("type", Json::string("response.create")),
      ])
      for key, value in fields {
        framed[key] = value
      }
      Json::object(framed)
    }
    other => other
  }
}

///|
/// Decide incremental vs full for this request. A delta is allowed only when
/// a completed response exists on the connection, every non-input field is
/// unchanged, and the new input extends the previous input followed by the
/// previous response's output items element-for-element. Anything else —
/// including any doubt — resends the full body, which is always wire-correct.
fn codex_ws_delta_request(body : Json, session : WsSession) -> Json {
  codex_ws_delta_parts(
    body,
    session.last_input,
    session.last_body_rest,
    session.last_response_id,
    session.last_response_items,
  )
}

///|
fn codex_ws_delta_parts(
  body : Json,
  last_input : Array[Json],
  last_body_rest : Json,
  last_response_id : String,
  last_response_items : Array[Json],
) -> Json {
  guard last_response_id.length() > 0 else { return body }
  guard body is Json::Object(fields) else { return body }
  let current_input : Array[Json] = match fields.get("input") {
    Some(Json::Array(items)) => items
    _ => return body
  }
  let rest = codex_ws_body_rest(body)
  guard rest == last_body_rest else { return body }
  let input_len = last_input.length()
  let items_len = last_response_items.length()
  let baseline_len = input_len + items_len
  guard current_input.length() > baseline_len else { return body }
  for i in 0..<input_len {
    guard current_input[i] == last_input[i] else { return body }
  }
  for j in 0..<items_len {
    guard current_input[input_len + j] == last_response_items[j] else {
      return body
    }
  }
  let delta : Array[Json] = []
  for k in baseline_len..<current_input.length() {
    delta.push(current_input[k])
  }
  let sent : Map[String, Json] = Map::from_array([])
  for key, value in fields {
    if key != "input" {
      sent[key] = value
    }
  }
  sent["previous_response_id"] = Json::string(last_response_id)
  sent["input"] = Json::array(delta)
  Json::object(sent)
}

///|
/// Collect the server-added output item from an `output_item.done` event —
/// these payloads are the continuation baseline for the next request.
fn codex_ws_capture_output_item(payload : String, sink : Array[Json]) -> Unit {
  let json = @json.parse(payload) catch { _ => return }
  guard json is Json::Object(fields) else { return }
  match fields.get("type") {
    Some(Json::String("response.output_item.done")) => ()
    _ => return
  }
  match fields.get("item") {
    Some(item) => sink.push(item)
    None => ()
  }
}

///|
fn codex_ws_capture_response_id(payload : String, sink : Ref[String]) -> Unit {
  let json = @json.parse(payload) catch { _ => return }
  guard json is Json::Object(fields) else { return }
  match fields.get("type") {
    Some(Json::String("response.completed")) => ()
    _ => return
  }
  match fields.get("response") {
    Some(Json::Object(response)) =>
      match response.get("id") {
        Some(Json::String(id)) if id.length() > 0 => sink.val = id
        _ => ()
      }
    _ => ()
  }
}

///|
priv enum WsChatOutcome {
  Done(@posoco.ModelCallResult)
  FallBack
}

///|
/// Stream one model request over the WebSocket transport with one reconnect
/// attempt on a fresh connection before the session falls back to SSE.
async fn OpenAIModelPort::codex_ws_chat(
  self : OpenAIModelPort,
  session_id : String,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> WsChatOutcome raise @posoco.ModelError {
  let body = openai_prepare_request(
    self.config,
    session_id,
    messages,
    tools,
    options,
    stream=true,
  )
  let session = match codex_ws_sessions.val.get(session_id) {
    Some(session) =>
      // A long-idle cached connection is presumed half-open: reconnect
      // instead of sending into a socket that would swallow the frame.
      if codex_ws_reuse_usable(session.last_activity_at_ms, @async.now()) {
        session
      } else {
        codex_ws_drop_session(session_id)
        match codex_ws_open_session(self.config, session_id) {
          Ok(fresh) => fresh
          Err(_) => {
            codex_ws_mark_session_fallback(session_id)
            return FallBack
          }
        }
      }
    None =>
      match codex_ws_open_session(self.config, session_id) {
        Ok(session) => session
        Err(_) => {
          codex_ws_mark_session_fallback(session_id)
          return FallBack
        }
      }
  }
  // A fresh connection carries no server state, so its first request is
  // always the full body (the continuation guard sees no completed id).
  let sent = codex_ws_delta_request(body, session)
  match session.transport.send_text(codex_ws_frame(sent).stringify()) {
    true => session.last_activity_at_ms = @async.now()
    false => {
      codex_ws_drop_session(session_id)
      codex_ws_mark_session_fallback(session_id)
      return FallBack
    }
  }
  // Record the logical request only after the send succeeds: the baseline is
  // the full body either way (a delta still advances the same conversation).
  match body {
    Json::Object(fields) =>
      match fields.get("input") {
        Some(Json::Array(items)) => session.last_input = items
        _ => ()
      }
    _ => ()
  }
  session.last_body_rest = codex_ws_body_rest(body)
  match
    codex_ws_pump(session_id, session, messages, self.quota_tracker, on_chunk) {
    Done(result) => Done(result)
    FallBack => {
      codex_ws_mark_session_fallback(session_id)
      FallBack
    }
  }
}

///|
async fn codex_ws_open_session(
  config : OpenAIConfig,
  session_id : String,
) -> Result[WsSession, String] noraise {
  let url = codex_ws_url(config.base_url)
  let headers = codex_ws_handshake_headers(config, session_id)
  let transport = match WsTransport::open(url, headers) {
    Ok(transport) => transport
    Err(message) => return Err(message)
  }
  let session = WsSession::{
    transport,
    last_input: [],
    last_body_rest: Json::object(Map::from_array([])),
    last_response_id: "",
    last_response_items: [],
    last_activity_at_ms: @async.now(),
  }
  codex_ws_sessions.val[session_id] = session
  Ok(session)
}

///|
/// Classify a `type: "error"` WS frame exactly like the HTTP path
/// classifies a non-2xx response: the shared chatkit classifier turns quota
/// phrasings into the typed `RateLimited` (reason, reset, provider code) so
/// the host's limit display and scheduled resume work unchanged; anything
/// else surfaces as a transport error carrying the provider's message.
fn codex_ws_provider_error_if_any(
  payload : String,
  now_ms~ : Int64,
) -> @posoco.ModelError? {
  let json = @json.parse(payload) catch { _ => return None }
  guard json is Json::Object(fields) else { return None }
  match fields.get("type") {
    Some(Json::String("error")) => ()
    _ => return None
  }
  let status = match fields.get("status") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 400
  }
  let body = match fields.get("error") {
    Some(err) => Json::object(Map::from_array([("error", err)]))
    _ => Json::object(fields)
  }
  let body_text = body.stringify()
  match
    @chatkit.classify_chat_completions_http_error(status, body_text, now_ms~) {
    Some(err) => Some(err)
    None =>
      // Unclassified provider error: keep the message visible.
      match fields.get("error") {
        Some(Json::Object(err)) =>
          match err.get("message") {
            Some(Json::String(message)) if message.length() > 0 =>
              Some(
                @posoco.ModelError::Transport(
                  "OpenAI SSE terminal failure (stage=error, category=provider_error, status=\{status}): \{message}",
                ),
              )
            _ => None
          }
        _ => None
      }
  }
}

///|
/// Read response events until completion. Any transport failure falls the
/// session back to SSE; a failure after the first emitted chunk raises
/// instead, so the caller never double-delivers. Kit-level model errors
/// propagate typed.
async fn codex_ws_pump(
  session_id : String,
  session : WsSession,
  messages : Array[@posoco.Message],
  quota_tracker : CodexQuotaTracker?,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> WsChatOutcome raise @posoco.ModelError {
  errdefer codex_ws_drop_session(session_id)
  let emitted = Ref::{ val: false, }
  let wrapped = fn(chunk : @posoco.StreamChunk) {
    emitted.val = true
    on_chunk(chunk)
  }
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let sse_state = @responses.SseStreamState::SseStreamState()
  let items : Array[Json] = []
  let response_id = Ref::{ val: "", }
  let mut done = false
  let mut last_yield = @async.now()
  while !done {
    match session.transport.next_text() {
      Err(message) => {
        if emitted.val {
          raise ws_stream_transport_error(message)
        }
        return FallBack
      }
      Ok(None) => {
        if emitted.val {
          raise ws_stream_transport_error("websocket closed before completion")
        }
        return FallBack
      }
      Ok(Some(text)) => {
        session.last_activity_at_ms = @async.now()
        let trimmed = text.trim().to_owned()
        if trimmed.length() > 0 {
          match codex_ws_provider_error_if_any(trimmed, now_ms=@async.now()) {
            Some(err) => raise err
            None => ()
          }
          // The WS counterpart of the quota header capture: reset times
          // ride these events, not HTTP headers.
          match quota_tracker {
            Some(tracker) =>
              codex_ws_capture_rate_limits(
                trimmed,
                tracker,
                fetched_at_ms=@async.now(),
              )
            None => ()
          }
          codex_ws_capture_output_item(trimmed, items)
          codex_ws_capture_response_id(trimmed, response_id)
          done = @responses.process_responses_sse(
            provider="OpenAI",
            trimmed,
            acc,
            wrapped,
            state=sse_state,
          )
        }
      }
    }
    // A buffered event burst can spin this loop without suspending; yield
    // at most every 16ms so the host keeps dispatching interrupts (the
    // pause is also the cancellation point).
    let now = @async.now()
    if now - last_yield >= 16L {
      @async.pause()
      last_yield = now
    }
  }
  session.last_response_id = response_id.val
  session.last_response_items = items
  let completion = attach_reasoning_items_responses(
    openai_stream_completion(acc),
    sse_state,
  )
  Done(@posoco.ModelCallResult::{ completion, processed_messages: messages, })
}

///|
/// Mid-stream transport failures keep the transient-retry wording the
/// router's classification keys on (same contract as the SSE read loop).
fn ws_stream_transport_error(message : String) -> @posoco.ModelError {
  @posoco.ModelError::Transport(
    "OpenAI transport failure (stage=read_stream): " + message,
  )
}
