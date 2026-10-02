///|
/// Port of compact_remote_v2.rs's ordinary 64k retention with image budget.
/// Cetas has no client-authored developer or AgentMessage metadata: do not
/// invent it from SystemMessage/assistant/tool text.
let compact_retained_message_token_budget : Int = 64_000

///|
fn compact_approx_tokens(text : String) -> Int {
  (@utf8.encode(text).length() + 3) / 4
}

///|
/// utils/string/truncate.rs: UTF-8-safe prefix/suffix, with the official
/// removed-token marker (the marker itself is not subtracted from budget).
fn compact_truncate_text(text : String, tokens : Int) -> String {
  let bytes = @utf8.encode(text)
  let budget = tokens * 4
  if bytes.length() <= budget {
    return text
  }
  let mut left = budget / 2
  let mut right = bytes.length() - (budget - left)
  while left > 0 && (bytes[left].to_int() & 0xc0) == 0x80 {
    left -= 1
  }
  while right < bytes.length() && (bytes[right].to_int() & 0xc0) == 0x80 {
    right += 1
  }
  let prefix = try! @utf8.decode(bytes[:left])
  let suffix = try! @utf8.decode(bytes[right:])
  let removed = (bytes.length() - budget + 3) / 4
  prefix + "…\{removed} tokens truncated…" + suffix
}

///|
fn compact_message_parts(item : Json) -> Array[Json] {
  match item {
    Json::Object(fields) =>
      match fields.get("content") {
        Some(Json::Array(parts)) => parts
        Some(Json::String(text)) =>
          [
            Json::object(
              Map::from_array([
                ("type", Json::string("input_text")),
                ("text", Json::string(text)),
              ]),
            ),
          ]
        _ => []
      }
    _ => []
  }
}

///|
fn compact_part_text(part : Json) -> String? {
  match part {
    Json::Object(fields) =>
      match (fields.get("type"), fields.get("text")) {
        (
          Some(Json::String("input_text" | "output_text")),
          Some(Json::String(text)),
        ) => Some(text)
        _ => None
      }
    _ => None
  }
}

///|
fn compact_message_text_tokens(item : Json) -> Int {
  let mut count = 0
  for part in compact_message_parts(item) {
    match compact_part_text(part) {
      Some(text) => count += compact_approx_tokens(text)
      None => ()
    }
  }
  count
}

///|
fn compact_image_resize_notice(item : Json) -> Bool {
  match item {
    Json::Object(fields) if fields.get("role") ==
      Some(Json::string("developer")) => {
      let parts = compact_message_parts(item)
      parts.length() == 1 &&
      (match compact_part_text(parts[0]) {
        Some(text) =>
          compact_fragment_matches(
            text, "<image_resize_notice>", "</image_resize_notice>",
          )
        None => false
      })
    }
    _ => false
  }
}

///|
fn compact_fragment_matches(
  text : String,
  open : String,
  close : String,
) -> Bool {
  let text = text.trim().to_owned().to_lower()
  text.has_prefix(open.to_lower()) && text.has_suffix(close.to_lower())
}

///|
/// The contextual user exclusions are source markers, not content heuristics.
/// Visible hook prompts take precedence over contextual fragments.
fn compact_contextual_user_text(text : String) -> Bool {
  for
    (open, close) in [
      ("# AGENTS.md instructions", "</INSTRUCTIONS>"),
      ("<environment_context>", "</environment_context>"),
      (
        "<agent_message_board_notification>", "</agent_message_board_notification>",
      ),
      ("<skill>", "</skill>"),
      ("<user_shell_command>", "</user_shell_command>"),
      ("<turn_aborted>", "</turn_aborted>"),
      ("<subagent_notification>", "</subagent_notification>"),
      ("<recommended_plugins>", "</recommended_plugins>"),
    ] {
    if compact_fragment_matches(text, open, close) {
      return true
    }
  }
  compact_internal_or_legacy_context(text)
}

///|
fn compact_retained_user(item : Json) -> Bool {
  guard item is Json::Object(fields) &&
    fields.get("role") == Some(Json::string("user")) else {
    return false
  }
  match fields.get("type") {
    None | Some(Json::String("message")) => ()
    _ => return false
  }
  let parts = compact_message_parts(item)
  let mut contextual = false
  let mut hook = false
  let mut hook_only = true
  for part in parts {
    match compact_part_text(part) {
      Some(text) =>
        if compact_visible_hook_text(text) {
          hook = true
        } else if compact_contextual_user_text(text) {
          contextual = true
        } else {
          hook_only = false
        }
      None => hook_only = false
    }
  }
  (hook && hook_only) || (!contextual && !hook)
}

///|
fn compact_truncate_message(item : Json, budget : Int) -> Json? {
  guard json_deep_copy(item) is Json::Object(fields) else { return None }
  let kept : Array[Json] = []
  let mut remaining = budget
  for part in compact_message_parts(Json::object(fields)) {
    match compact_part_text(part) {
      Some(text) => {
        if remaining == 0 {
          continue
        }
        let tokens = compact_approx_tokens(text)
        let text = if tokens <= remaining {
          remaining -= tokens
          text
        } else {
          let value = compact_truncate_text(text, remaining)
          remaining = 0
          value
        }
        if !text.is_empty() {
          guard part is Json::Object(part_fields) else { abort("text part") }
          part_fields["text"] = Json::string(text)
          kept.push(part)
        }
      }
      None => kept.push(part)
    }
  }
  if kept.is_empty() {
    return None
  }
  fields["content"] = Json::array(kept)
  Some(Json::object(fields))
}

///|
fn compact_v2_retained_history(
  history : Array[Json],
  budget? : Int = compact_retained_message_token_budget,
) -> Array[Json] {
  let groups : Array[(Json, Json?)] = []
  let mut i = 0
  while i < history.length() {
    let source = history[i]
    let notice = if i + 1 < history.length() &&
      compact_image_resize_notice(history[i + 1]) {
      Some(history[i + 1])
    } else {
      None
    }
    i += if notice is Some(_) { 2 } else { 1 }
    if compact_retained_user(source) {
      groups.push((source, notice))
    }
  }
  let reversed : Array[Json] = []
  let mut remaining = budget
  for i = groups.length() - 1; i >= 0; i = i - 1 {
    if remaining == 0 {
      continue
    }
    let (source, notice) = groups[i]
    let notice_tokens = match notice {
      Some(item) => compact_message_text_tokens(item).max(1)
      None => 0
    }
    let tokens = compact_message_content_tokens(source).max(1) + notice_tokens
    let kept = if tokens <= remaining {
      remaining -= tokens
      Some(json_deep_copy(source))
    } else if remaining > notice_tokens {
      let image = compact_has_image(source)
      let available = remaining - notice_tokens
      if image {
        remaining = 0
      }
      let truncated = if image {
        compact_truncate_image_message(source, available)
      } else {
        compact_truncate_message(source, available)
      }
      if truncated is Some(_) {
        remaining = 0
      }
      truncated
    } else {
      if compact_has_image(source) {
        remaining = 0
      }
      None
    }
    match kept {
      Some(source) => {
        match notice {
          Some(item) => reversed.push(json_deep_copy(item))
          None => ()
        }
        reversed.push(source)
      }
      None => ()
    }
  }
  [
    for i = reversed.length() - 1; i >= 0; i = i - 1 => reversed[i]
  ]
}

///|
/// The raw anchor stores latest retained history plus the new opaque item;
/// the checked canonical projection is for display/persistence, never replay.
fn compact_latest_window(
  history : Array[Json],
) -> Array[@posoco.Message] raise @posoco.ModelError {
  let window : Array[@posoco.Message] = [
    @posoco.Message::AssistantMessage(
      content=[],
      tool_calls=[],
      reasoning=Some(compact_raw_anchor_reasoning(history)),
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  for message in compact_projection_of(history) {
    window.push(message)
  }
  window
}
