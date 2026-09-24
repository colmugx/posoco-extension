///|
/// Render a transcript span as plain text for the summary request, so the
/// summarizer model reads it as material rather than a conversation to
/// continue.
///
/// Line prefixes: `[System]: `, `[User]: `, `[Assistant]: `, inline
/// `[Assistant tool call]: name(json-args)` lines, `[Tool result]: `,
/// `[Tool error]: ` (both tool-reported errors and runtime failures), and
/// `[Tool not executed]`. Images become `[image: media_type]` placeholders.
/// Tool-call arguments compact long string leaves and are capped at 2000
/// characters; tool output longer than `tool_output_char_limit` is cut to
/// the limit and suffixed with `"\n[truncated]"`. Messages are joined with
/// a blank line.
///|
/// Preserve enough of each long string argument to identify both its opening
/// and ending context (important for edits/code), while avoiding full file
/// bodies in the summary request.
const SUMMARY_TOOL_ARG_STRING_CHARS = 600

///|
/// Hard cap for one serialized tool-call argument object in the summary
/// request, after per-string compaction.
const SUMMARY_TOOL_ARGS_CHARS = 2000

///|
fn char_count(text : String) -> Int {
  let mut count = 0
  for _ in text {
    count += 1
  }
  count
}

///|
fn tail_chars(text : String, total_chars : Int, limit : Int) -> String {
  if limit <= 0 {
    return ""
  }
  let skip = total_chars - limit
  let chars : Array[Char] = []
  let mut index = 0
  for ch in text {
    if index >= skip {
      chars.push(ch)
    }
    index += 1
  }
  String::from_array(chars)
}

///|
fn clamp_inline(text : String, limit : Int) -> String {
  if limit <= 0 {
    return text
  }
  let total = char_count(text)
  if total <= limit {
    return text
  }
  let marker = "…[cut]…"
  let marker_chars = char_count(marker)
  let remaining = limit - marker_chars
  if remaining <= 0 {
    return take_chars(marker, limit)
  }
  let head = remaining / 2
  let tail = remaining - head
  take_chars(text, head) + marker + tail_chars(text, total, tail)
}

///|
/// Compact only tool-call arguments. Conversational content remains lossless.
/// JSON shape, keys, numbers and booleans are retained; long string leaves
/// keep head+tail context before the whole serialized argument object receives
/// a final hard cap.
fn compact_tool_arg_json(value : Json) -> Json {
  match value {
    Json::String(text) =>
      Json::string(clamp_inline(text, SUMMARY_TOOL_ARG_STRING_CHARS))
    Json::Array(items) => {
      let out : Array[Json] = []
      for item in items {
        out.push(compact_tool_arg_json(item))
      }
      Json::array(out)
    }
    Json::Object(fields) => {
      let out : Map[String, Json] = Map::from_array([])
      for key, item in fields {
        out[key] = compact_tool_arg_json(item)
      }
      Json::object(out)
    }
    other => other
  }
}

///|
fn render_tool_args(arguments : Json) -> String {
  clamp_inline(
    compact_tool_arg_json(arguments).stringify(),
    SUMMARY_TOOL_ARGS_CHARS,
  )
}

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
          "[Assistant tool call]: \{call.name.to_string()}(\{render_tool_args(call.arguments)})",
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
