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
pub extend TurnVerdict with Eq::{not_equal, equal}

///|
pub extend TurnVerdict with @moonbitlang/core/debug.Debug::{to_repr}

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
/// The marker is only a protocol signal when it is the last non-empty line
/// of an assistant message. Earlier marker examples, quotations, and user
/// messages never authorize goal completion or blocking.
///
/// For BlockedClaimed the reason is the last non-empty preceding line,
/// truncated to 200 UTF-16 code units.
pub fn scan_final_message(
  message~ : @posoco.Message,
  completion_marker~ : String,
  blocked_marker~ : String,
) -> TurnVerdict {
  let content = match message {
    @posoco.Message::AssistantMessage(content~, ..) => content
    _ => return NoSignal
  }
  let lines : Array[String] = []
  for line in text_of_content(content).split("\n") {
    lines.push(line.trim().to_owned())
  }
  // Trailing whitespace is harmless; non-marker prose after a tag is not.
  let mut last_nonempty : Int32? = None
  for i, line in lines {
    if line != "" {
      last_nonempty = Some(i)
    }
  }
  match last_nonempty {
    None => NoSignal
    Some(i) => {
      if lines[i] == completion_marker {
        return CompletionClaimed
      }
      if lines[i] != blocked_marker {
        return NoSignal
      }
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
