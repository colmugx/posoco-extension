///|
/// Render a transcript span as plain text for the summary request, so the
/// summarizer model reads it as material rather than a conversation to
/// continue.
///
/// Line prefixes: `[System]: `, `[User]: `, `[Assistant]: `, inline
/// `[Assistant tool call]: name(json-args)` lines, `[Tool result]: `,
/// `[Tool error]: ` (both tool-reported errors and runtime failures), and
/// `[Tool not executed]`. Images become `[image: media_type]` placeholders.
/// Tool output longer than `tool_output_char_limit` is cut to the limit and
/// suffixed with `"\n[truncated]"`. Messages are joined with a blank line.
pub fn serialize_for_summary(
  messages : Array[@posoco.Message],
  tool_output_char_limit? : Int = 2000,
) -> String {
  let blocks : Array[String] = []
  for message in messages {
    blocks.push(render_message(message, tool_output_char_limit))
  }
  blocks.join("\n\n")
}

///|
fn render_message(message : @posoco.Message, limit : Int) -> String {
  match message {
    SystemMessage(content~) => "[System]: " + render_content(content)
    UserMessage(content~) => "[User]: " + render_content(content)
    AssistantMessage(content~, tool_calls~, ..) => {
      let lines : Array[String] = []
      let text = render_content(content)
      if text != "" {
        lines.push("[Assistant]: " + text)
      }
      for call in tool_calls {
        lines.push(
          "[Assistant tool call]: \{call.name.to_string()}(\{call.arguments.stringify()})",
        )
      }
      lines.join("\n")
    }
    ToolMessage(outcome~, ..) =>
      match outcome {
        Success(content~, ..) =>
          "[Tool result]: " + clamp_tool_output(content, limit)
        ToolReportedError(content~, ..) =>
          "[Tool error]: " + clamp_tool_output(content, limit)
        RuntimeFailure(message~, ..) =>
          "[Tool error]: " + clamp_tool_output(message, limit)
        NotExecuted(..) => "[Tool not executed]"
      }
  }
}

///|
fn render_content(content : Array[@posoco.Content]) -> String {
  let parts : Array[String] = []
  for block in content {
    match block {
      Text(text) => parts.push(text)
      Image(media_type~, ..) => parts.push("[image: \{media_type}]")
    }
  }
  parts.join(" ")
}

///|
/// Cut tool output to `limit` chars with a `"\n[truncated]"` suffix.
/// `limit <= 0` disables truncation. Cutting counts chars (not UTF-16 code
/// units) so a surrogate pair is never split.
fn clamp_tool_output(text : String, limit : Int) -> String {
  if limit > 0 && text.length() > limit {
    take_chars(text, limit) + "\n[truncated]"
  } else {
    text
  }
}

///|
fn take_chars(text : String, limit : Int) -> String {
  let chars : Array[Char] = []
  let mut taken = 0
  for ch in text {
    if taken >= limit {
      break
    }
    chars.push(ch)
    taken += 1
  }
  String::from_array(chars)
}
