///|
/// Concatenated text of the Text items of a Content array.
fn text_of_content(content : Array[@posoco.Content]) -> String {
  content
  .filter_map(fn(c) {
    match c {
      @posoco.Content::Text(t) => Some(t)
      _ => None
    }
  })
  .join("")
}

///|
/// Text of a message; ToolMessage carries no assistant text → ""
fn text_of_message(message : @posoco.Message) -> String {
  match message {
    @posoco.Message::SystemMessage(content~) => text_of_content(content)
    @posoco.Message::UserMessage(content~) => text_of_content(content)
    @posoco.Message::AssistantMessage(content~, ..) => text_of_content(content)
    @posoco.Message::ToolMessage(..) => ""
  }
}

///|
/// What the final assistant message of a turn signals.
pub(all) enum TurnVerdict {
  NoSignal
  CompletionClaimed
  BlockedClaimed(reason~ : String)
} derive(Eq, Debug)

///|
/// Truncate a reason to 200 UTF-16 code units, appending "…" when truncated.
/// Character iteration keeps surrogate pairs intact where slicing could not.
fn truncate_reason(reason : String) -> String {
  if reason.length() <= 200 {
    return reason
  }
  let sb = StringBuilder()
  let mut units = 0
  for c in reason {
    let width = if c.to_int() > 0xFFFF { 2 } else { 1 }
    if units + width > 200 {
      break
    }
    sb.write_char(c)
    units += width
  }
  sb.to_string() + "…"
}

///|
/// Scan the message text line by line. A signal line is one whose TRIMMED
/// content EXACTLY equals the completion or blocked marker. When several
/// signal lines exist, the LAST one wins (final intent). For BlockedClaimed
/// the reason is the last non-empty line ABOVE that tag line, truncated to
/// 200 characters (append "…" when truncated); "" when none.
pub fn scan_final_message(
  message~ : @posoco.Message,
  completion_marker~ : String,
  blocked_marker~ : String,
) -> TurnVerdict {
  let lines : Array[String] = []
  for line in text_of_message(message).split("\n") {
    lines.push(line.trim().to_owned())
  }
  let mut last_signal_index : Int? = None
  let mut last_is_completion = false
  for i, line in lines {
    if line == completion_marker {
      last_signal_index = Some(i)
      last_is_completion = true
    } else if line == blocked_marker {
      last_signal_index = Some(i)
      last_is_completion = false
    }
  }
  match last_signal_index {
    None => NoSignal
    Some(i) =>
      if last_is_completion {
        CompletionClaimed
      } else {
        let mut reason = ""
        for j in 0..<i {
          if lines[j] != "" {
            reason = lines[j]
          }
        }
        BlockedClaimed(reason=truncate_reason(reason))
      }
  }
}
