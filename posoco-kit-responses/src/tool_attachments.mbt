///|
/// Placeholder for an image the endpoint or model cannot accept. Same
/// discipline and size estimate as the chat-completions kit (kept local:
/// coupling two wire kits for a string literal is worse than six lines).
fn image_placeholder(media_type : String, data : String) -> String {
  let approx_kb = data.length() * 3 / 4096
  "[Attached " +
  media_type +
  ", ~" +
  approx_kb.to_string() +
  " KB, omitted: this model does not accept image input]"
}

///|
fn outcome_attachments(outcome : @posoco.ToolOutcome) -> Array[@posoco.Content] {
  match outcome {
    SuccessWithAttachments(attachments~, ..) => attachments
    _ => []
  }
}

///|
/// Fold tool-result attachments into Responses API input shape at the
/// message level (mirror of the chat-completions kit fold — the wire
/// strategies differ per protocol family):
/// - `supports_images=true`: a contiguous run of tool outputs keeps its
///   `function_call_output` items, and the run's attachments collapse into
///   ONE synthetic `user` message right after the run (rendered as
///   `input_image` parts by the standard content conversion).
/// - `supports_images=false`: every attachment degrades to the explicit
///   `[Attached …, omitted]` placeholder appended to its output text — never
///   a silent drop.
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

///|
fn outcome_wire_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    SuccessWithAttachments(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(reason~, ..) => reason.to_string()
  }
}
