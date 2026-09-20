// The activation header template (Q4): every activation — meta tool or
// manual — injects one UserMessage whose first Text line is exactly
// `"profile <id> activated"`. The line is the durable activation record:
// compact must preserve it (Q14) and the scanner below rebuilds the
// activated set from it, so the template is frozen contract, not
// presentation.

///|
/// Build the activation header line for one profile id.
pub fn activation_header(id : String) -> String {
  "profile " + id + " activated"
}

///|
/// Reconstruct the activated profile set from a transcript (Q14/Q18). The
/// transcript is the single source of truth and the extension keeps zero
/// activation memory: scanning every UserMessage's first Text line for the
/// exact header format rebuilds the set — on resume, after compact, and
/// before each model request, from the same one function. Returns ids in
/// first-seen order, deduplicated.
pub fn scan_activated_profiles(
  messages : Array[@posoco.Message],
) -> Array[String] {
  let found : Array[String] = []
  for message in messages {
    match message {
      @posoco.Message::UserMessage(content~) =>
        match content {
          [@posoco.Content::Text(text), ..] =>
            match header_profile_id(first_line(text)) {
              Some(id) => if !found.contains(id) { found.push(id) }
              None => ()
            }
          _ => ()
        }
      _ => ()
    }
  }
  found
}

///|
/// Pending profile activations (Q18): ids whose activation tool call
/// succeeded but whose header line is not yet in the transcript — exactly
/// what before_model must inject this request.
///
/// A call contributes a pending id only when all of the following hold:
/// - an AssistantMessage tool call names the `activate_profile` tool,
/// - its arguments carry a string `profile` field (missing/non-string is
///   undecidable — the call is skipped),
/// - a ToolMessage with the same call id exists (the call was executed) and
///   its `Success` content first line starts with `activated: `.
///
/// **Package-core invariant**: the `activated: <id>` success prefix and the
/// `unknown profile: <id>` miss prefix are produced by this package's
/// `activate_profile` meta tool (Wave 2) and consumed here. A first line
/// starting with `unknown profile` is an explicit never-inject verdict; any
/// other content shape or error outcome does not inject. Keep both sides in
/// sync.
///
/// Results are ordered by first appearance, deduplicated, and already
/// injected ids (per `scan_activated_profiles`) are excluded — re-injecting
/// an activated profile is a no-op (Q16).
pub fn find_pending_activations(
  messages : Array[@posoco.Message],
) -> Array[String] {
  let injected = scan_activated_profiles(messages)
  let pending : Array[String] = []
  for message in messages {
    match message {
      @posoco.Message::AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          if call.name.to_string() == "activate_profile" {
            match call_profile_id(call) {
              Some(id) =>
                if !injected.contains(id) && !pending.contains(id) {
                  match activation_result_verdict(messages, call.call_id) {
                    Some(true) => pending.push(id)
                    _ => ()
                  }
                }
              None => ()
            }
          }
        }
      _ => ()
    }
  }
  pending
}

///|
/// The requested profile id of an `activate_profile` tool call. A missing or
/// non-string `profile` field makes the call undecidable.
fn call_profile_id(call : @posoco.ToolCall) -> String? {
  match call.arguments {
    Json::Object(fields) =>
      match fields.get("profile") {
        Some(Json::String(id)) => Some(id)
        _ => None
      }
    _ => None
  }
}

///|
/// Verdict of the executed tool result for one call id. `Some(true)` = the
/// result activated the profile; `Some(false)` = explicit miss (first line
/// starts with `unknown profile`); `None` = no executed Success result with
/// a recognized verdict (never executed, error outcome, foreign text).
fn activation_result_verdict(
  messages : Array[@posoco.Message],
  target : @posoco.CallId,
) -> Bool? {
  for message in messages {
    match message {
      @posoco.Message::ToolMessage(call_id~, outcome~, ..) =>
        if call_id == target {
          match outcome {
            @posoco.ToolOutcome::Success(content~, ..) => {
              let line = first_line(content)
              if line.has_prefix("activated: ") {
                return Some(true)
              }
              if line.has_prefix("unknown profile") {
                return Some(false)
              }
            }
            _ => ()
          }
        }
      _ => ()
    }
  }
  None
}

///|
/// Strict header match: the line must be exactly `profile <id> activated`
/// with a non-empty id (Q4 template). Prose merely mentioning the phrase, a
/// compact summary line, or a differently-shaped message yields None.
fn header_profile_id(line : String) -> String? {
  let prefix = "profile "
  let suffix = " activated"
  if !line.has_prefix(prefix) || !line.has_suffix(suffix) {
    return None
  }
  let body_length = line.length() - prefix.length() - suffix.length()
  if body_length <= 0 {
    return None
  }
  let body = line[prefix.length():prefix.length() + body_length]
  Some(body.to_owned())
}

///|
/// First line of a multi-line text. Total by construction: never raises and
/// never splits a surrogate pair.
fn first_line(text : String) -> String {
  let chars : Array[Char] = []
  for ch in text {
    if ch == '\n' {
      break
    }
    chars.push(ch)
  }
  String::from_array(chars)
}
