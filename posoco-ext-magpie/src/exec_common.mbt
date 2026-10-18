///|
/// exec_common.mbt — shared execution plumbing: HTTP status classification,
/// session identity, endpoint resolution, and image shaping.
///
/// Diagnostics discipline: error messages carry stages, statuses, and body
/// sizes — never bodies, headers, credentials, or session identifiers.

///|
/// The canonical gateway path each protocol is spoken at. Native plans use
/// the declared path (which equals this); translated plans speak the
/// protocol at the gateway's canonical endpoint and let the gateway convert.
pub fn MagpieProtocol::canonical_path(self : MagpieProtocol) -> String {
  match self {
    Messages => "/v1/messages"
    Responses => "/v1/responses"
    ChatCompletions => "/v1/chat/completions"
  }
}

///|
/// Bounded error-body capture: at most 2048 chars are read for diagnostics.
const MAX_ERROR_BODY_CHARS : Int32 = 2048

///|
fn is_http_success(code : Int32) -> Bool {
  code >= 200 && code < 300
}

///|
/// Drains an open stream into a bounded error-body string and closes it.
async fn drain_error_body(
  stream : &MagpieEventStream,
) -> String raise MagpieGatewayError {
  let mut text = ""
  let mut done = false
  while !done {
    match stream.next_line() {
      Some(line) => {
        text = text + line
        if text.length() > MAX_ERROR_BODY_CHARS {
          done = true
        }
      }
      None => done = true
    }
  }
  stream.close_stream()
  text
}

///|
/// Classifies a non-2xx gateway status into a Posoco model error.
/// 429 goes through the rate-limit kit (reset extraction stays structured).
/// HTTP 408 and 5xx are transient gateway failures, scheduled by Posoco's
/// rate-limit recovery actor. Authentication and request errors stay terminal.
/// Bodies are counted, never quoted.
fn classify_http_error(
  stage : String,
  code : Int32,
  body_text : String,
  now_ms~ : Int64,
) -> @posoco.ModelError? {
  if is_http_success(code) {
    return None
  }
  if code == 429 {
    return @ratelimit.classify_rate_limit_error(
      code,
      body_text,
      default_tz_offset_minutes=0,
      now_ms~,
    )
  }
  if code == 408 || (code >= 500 && code <= 599) {
    return Some(magpie_transient_error("http", "status_\{code}"))
  }
  Some(
    @posoco.ModelError::Transport(
      "magpie HTTP error (stage=\{stage}, status=\{code}, body_chars=\{body_text.length()})",
    ),
  )
}

///|
/// Raises the classified error when the status is not a success.
fn require_http_success(
  stage : String,
  code : Int32,
  body_text : String,
) -> Unit raise @posoco.ModelError {
  match classify_http_error(stage, code, body_text, now_ms=@async.now()) {
    Some(error) => raise error
    None => ()
  }
}

///|
/// Maps a transport-level failure onto the Posoco error vocabulary from the
/// error's structural text. Errors quote facts, never bodies or headers.

///|
/// A retryable failure without a provider deadline. The recovery guard owns
/// backoff; do not fabricate a provider reset timestamp here.
fn magpie_transient_error(
  stage : String,
  category : String,
) -> @posoco.ModelError {
  @posoco.ModelError::RateLimited(@posoco.RateLimitInfo::{
    message: "magpie transient failure (stage=\{stage}, category=\{category})",
    reset_at_ms: None,
    provider_code: Some("magpie_transient"),
  })
}

///|
/// Only Magpie's well-known stream-failure envelope is retryable. Arbitrary
/// upstream error text, policy refusals and auth failures stay terminal.
/// We only inspect the error shape; no provider text enters diagnostics.
fn magpie_stream_transient(payload : String) -> Bool {
  let json : Json = @json.parse(payload) catch { _ => Json::null() }
  guard json is Json::Object(root) else { return false }
  let err = match root.get("error") {
    Some(Json::Object(fields)) => Some(fields)
    _ =>
      match root.get("response") {
        Some(Json::Object(response)) =>
          match response.get("error") {
            Some(Json::Object(fields)) => Some(fields)
            _ => None
          }
        _ => None
      }
  }
  guard err is Some(fields) else { return false }
  let message = match fields.get("message") {
    Some(Json::String(value)) => value.to_lower()
    _ => ""
  }
  let code = match (fields.get("type"), fields.get("code")) {
    (Some(Json::String(kind)), _) => kind
    (_, Some(Json::String(kind))) => kind
    _ => ""
  }
  (code == "api_error" || code == "server_error") &&
  (
    message.contains("connection lost mid-reply") ||
    message.contains("stream ended before") ||
    message.contains("upstream died mid-reply")
  )
}

///|
fn transport_error(stage : String, detail : String) -> @posoco.ModelError {
  let lower = detail.to_lower()
  // User-initiated cancellation must never restart an intentionally stopped
  // turn, even when it surfaces as a transport exception.
  if !lower.contains("cancel") && !lower.contains("abort") {
    return magpie_transient_error(stage, "connection")
  }
  @posoco.ModelError::Transport(
    "magpie transport failure (stage=\{stage}): \{detail}",
  )
}

///|
/// Builds execution headers: the configured credential, JSON content
/// negotiation, and the Magpie session affinity header when a session
/// identity exists. Built fresh per request; never logged.
fn exec_headers(
  config : MagpieConfig,
  session_id : String?,
  streaming~ : Bool = false,
) -> Map[String, String] raise @posoco.ModelError {
  let token = match effective_token(config) {
    Some(token) => token
    None =>
      raise @posoco.ModelError::RequestBuild(
        "magpie request build failure (stage=headers): remote gateway requires an explicitly configured credential",
      )
  }
  let headers = gateway_headers(token)
  headers["Content-Type"] = "application/json"
  headers["Accept"] = if streaming {
    "text/event-stream"
  } else {
    "application/json"
  }
  match session_id {
    Some(id) =>
      if id != "" {
        // Stable per-session affinity: the gateway keys routing and account
        // decisions on this value; it is passed through verbatim and never
        // logged.
        headers["X-Magpie-Session"] = id
      }
    None => ()
  }
  headers
}

///|
/// The session identity for one call: the Posoco session id, stable across
/// turns of the same session and distinct across sessions. `None` = the
/// scope carried no usable identity; the request then runs without the
/// affinity header instead of inventing one.
fn session_identity(scope : @posoco.InvocationScope) -> String? {
  let id = scope.session_id.to_string()
  if id is "" {
    None
  } else {
    Some(id)
  }
}

///|
/// Resolves the endpoint the plan selected: the declared native path, or
/// the protocol's canonical gateway path for translated execution.
fn execution_endpoint(
  config : MagpieConfig,
  plan : MagpieProtocolPlan,
) -> String {
  let path = match plan.endpoint_path {
    Some(path) => path
    None => plan.protocol.canonical_path()
  }
  gateway_url(config, path)
}

///|
/// Placeholder for an image the model cannot accept; size is the decoded-
/// byte estimate so the model can gauge what was attached.
fn image_placeholder_text(media_type : String, data : String) -> String {
  let approx_kb = data.length() * 3 / 4096
  "[Attached \{media_type}, ~\{approx_kb} KB, omitted: this model does not accept image input]"
}

///|
fn downgrade_image_blocks(
  blocks : Array[@posoco.Content],
) -> Array[@posoco.Content] {
  blocks.map(fn(block) {
    match block {
      @posoco.Content::Image(media_type~, data~) =>
        @posoco.Content::Text(image_placeholder_text(media_type, data))
      text => text
    }
  })
}

///|
fn downgrade_tool_outcome(outcome : @posoco.ToolOutcome) -> @posoco.ToolOutcome {
  match outcome {
    @posoco.ToolOutcome::SuccessWithAttachments(
      content~,
      structured~,
      attachments~
    ) => {
      let merged = StringBuilder()
      merged.write_string(content)
      for block in attachments {
        merged.write_string("\n")
        match block {
          @posoco.Content::Image(media_type~, data~) =>
            merged.write_string(image_placeholder_text(media_type, data))
          @posoco.Content::Text(text) => merged.write_string(text)
        }
      }
      @posoco.ToolOutcome::SuccessWithAttachments(
        content=merged.to_string(),
        structured~,
        attachments=[],
      )
    }
    other => other
  }
}

///|
/// Pre-encode shaping for models without declared image input: images and
/// tool attachments become explicit placeholders — never a silent drop.
/// Models with declared image input (or unknown modalities) pass through.
fn shape_for_images(
  messages : Array[@posoco.Message],
  supports_images : Bool,
) -> Array[@posoco.Message] {
  if supports_images {
    return messages
  }
  messages.map(fn(msg) {
    match msg {
      @posoco.Message::SystemMessage(content~) =>
        @posoco.Message::SystemMessage(content=downgrade_image_blocks(content))
      @posoco.Message::UserMessage(content~) =>
        @posoco.Message::UserMessage(content=downgrade_image_blocks(content))
      @posoco.Message::ToolMessage(call_id~, tool_name~, outcome~) =>
        @posoco.Message::ToolMessage(
          call_id~,
          tool_name~,
          outcome=downgrade_tool_outcome(outcome),
        )
      assistant => assistant
    }
  })
}

///|
/// Whether the transcript carries image content anywhere.
fn transcript_has_images(messages : Array[@posoco.Message]) -> Bool {
  messages
  .iter()
  .any(fn(msg) {
    match msg {
      @posoco.Message::SystemMessage(content~)
      | @posoco.Message::UserMessage(content~) =>
        content.iter().any(fn(block) { block is @posoco.Content::Image(_) })
      @posoco.Message::ToolMessage(outcome~, ..) =>
        match outcome {
          @posoco.ToolOutcome::SuccessWithAttachments(attachments~, ..) =>
            attachments
            .iter()
            .any(fn(block) { block is @posoco.Content::Image(_) })
          _ => false
        }
      _ => false
    }
  })
}

///|
/// All system content lifts to the top-level `system` field (in order);
/// the transcript itself never carries a system role in the Messages dialect.
fn split_system(
  messages : Array[@posoco.Message],
) -> (Array[@posoco.Content], Array[@posoco.Message]) {
  let system : Array[@posoco.Content] = []
  let transcript : Array[@posoco.Message] = []
  for msg in messages {
    match msg {
      @posoco.Message::SystemMessage(content~) =>
        for block in content {
          system.push(block)
        }
      other => transcript.push(other)
    }
  }
  (system, transcript)
}

///|
/// Images pass through when the catalog has not declared modalities.
/// Unknown is NOT a declaration of text-only input, and rewriting unknown
/// images into placeholders silently loses user content. Explicit text-only
/// declarations are blocked by protocol planning before execution.
fn model_supports_images(entry : MagpieCatalogEntry) -> Bool {
  match entry.meta.modalities_input {
    Some(inputs) => inputs.contains("image")
    None => true
  }
}
