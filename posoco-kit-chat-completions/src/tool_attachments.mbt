///|
/// Plain-text projection of a tool outcome (attachments contribute nothing
/// here; they travel the message-level strategy below).
pub fn outcome_wire_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    SuccessWithAttachments(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(reason~, ..) => reason.to_string()
  }
}

///|
fn outcome_attachments(outcome : @posoco.ToolOutcome) -> Array[@posoco.Content] {
  match outcome {
    SuccessWithAttachments(attachments~, ..) => attachments
    _ => []
  }
}

///|
/// Fold tool-result attachments into the chat-completions wire shape.
///
/// The `tool` role carries only a text `content` string on this protocol, so
/// attachment blocks cannot ride the tool message itself:
/// - `supports_images=true`: a contiguous run of tool messages keeps its
///   text, and the run's attachments collapse into ONE synthetic user
///   message emitted right after the run. The fold is a pure function of the
///   message array, so provider prefix caches replay identically.
/// - `supports_images=false`: every attachment degrades to the explicit
///   `[Attached …, omitted]` placeholder appended to its tool text — never a
///   silent drop.
pub fn fold_tool_attachments(
  messages : Array[@posoco.Message],
  supports_images : Bool,
) -> Array[@posoco.Message] {
  let out : Array[@posoco.Message] = []
  let run : Array[@posoco.Message] = []
  let blocks : Array[@posoco.Content] = []
  for msg in messages {
    match msg {
      @posoco.Message::ToolMessage(outcome~, ..) => {
        run.push(msg)
        for block in outcome_attachments(outcome) {
          blocks.push(block)
        }
      }
      _ => {
        flush_tool_run(out, run, blocks, supports_images)
        out.push(msg)
      }
    }
  }
  flush_tool_run(out, run, blocks, supports_images)
  out
}

///|
/// Emit one buffered tool run: keep the messages as-is and append the
/// synthetic media message, or degrade every attachment to a placeholder.
fn flush_tool_run(
  out : Array[@posoco.Message],
  run : Array[@posoco.Message],
  blocks : Array[@posoco.Content],
  supports_images : Bool,
) -> Unit {
  if run.is_empty() {
    return
  }
  if supports_images {
    for msg in run {
      out.push(msg)
    }
    if !blocks.is_empty() {
      let content : Array[@posoco.Content] = [
        @posoco.Content::Text("[media attachments from the tool results above]"),
      ]
      for block in blocks {
        content.push(block)
      }
      out.push(@posoco.Message::UserMessage(content~))
    }
  } else {
    for msg in run {
      out.push(degrade_tool_attachments(msg))
    }
  }
  run.clear()
  blocks.clear()
}

///|
/// Append explicit omission placeholders for a tool message's attachments
/// (endpoint or model cannot accept image input).
fn degrade_tool_attachments(msg : @posoco.Message) -> @posoco.Message {
  match msg {
    @posoco.Message::ToolMessage(call_id~, tool_name~, outcome~) => {
      let attachments = outcome_attachments(outcome)
      if attachments.is_empty() {
        msg
      } else {
        let builder = StringBuilder()
        builder.write_string(outcome_wire_text(outcome))
        for block in attachments {
          match block {
            @posoco.Content::Image(media_type~, data~) =>
              builder.write_string(image_placeholder(media_type, data))
            @posoco.Content::Text(_) => ()
          }
        }
        @posoco.Message::ToolMessage(
          call_id~,
          tool_name~,
          outcome=@posoco.ToolOutcome::Success(
            content=builder.to_string(),
            structured=None,
          ),
        )
      }
    }
    _ => msg
  }
}
