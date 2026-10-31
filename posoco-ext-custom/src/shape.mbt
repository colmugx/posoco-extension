///|
/// shape.mbt — transcript shaping shared by the messages and responses wires.
///
/// Both dialects place the base instruction outside the message list (Messages
/// takes a top-level `system` field; Responses takes `instructions`), and both
/// reject image blocks in positions they do not support. Shaping happens once,
/// up front, so a model without declared image input receives an explicit
/// placeholder instead of a silent drop or a 400.

///|
/// Placeholder for an image the model cannot accept: a decoded-byte size
/// estimate so the model can gauge the attachment without seeing it.
fn custom_image_placeholder(media_type : String, data : String) -> String {
  let approx_kb = data.length() * 3 / 4096
  "[Attached " +
  media_type +
  ", ~" +
  approx_kb.to_string() +
  " KB, omitted: this model does not accept image input]"
}

///|
/// Image downgrade for wires that gate images per message position: images in
/// message content and tool outcomes become explicit text placeholders. Text
/// passes through untouched.
fn shape_custom_images(
  messages : Array[@posoco.Message],
  supports_images : Bool,
) -> Array[@posoco.Message] {
  if supports_images {
    return messages
  }
  messages.map(fn(msg) {
    match msg {
      SystemMessage(content~) =>
        SystemMessage(
          content=content.map(fn(block) {
            match block {
              Image(media_type~, data~) =>
                Text(custom_image_placeholder(media_type, data))
              text => text
            }
          }),
        )
      UserMessage(content~) =>
        UserMessage(
          content=content.map(fn(block) {
            match block {
              Image(media_type~, data~) =>
                Text(custom_image_placeholder(media_type, data))
              text => text
            }
          }),
        )
      AssistantMessage(..) => msg
      ToolMessage(call_id~, tool_name~, outcome~) =>
        ToolMessage(
          call_id~,
          tool_name~,
          outcome=match outcome {
            SuccessWithAttachments(content~, structured~, attachments~) => {
              let merged = StringBuilder()
              merged.write_string(content)
              for block in attachments {
                merged.write_string("\n")
                match block {
                  Image(media_type~, data~) =>
                    merged.write_string(
                      custom_image_placeholder(media_type, data),
                    )
                  Text(text) => merged.write_string(text)
                }
              }
              SuccessWithAttachments(content=merged.to_string(), structured~, attachments=[])
            }
            other => other
          },
        )
    }
  })
}

///|
/// Split the transcript into base-instruction content and the conversation.
/// System turns lift out of the message list on both non-chat wires.
fn custom_split_system(
  messages : Array[@posoco.Message],
) -> (Array[@posoco.Content], Array[@posoco.Message]) {
  let system : Array[@posoco.Content] = []
  let rest : Array[@posoco.Message] = []
  for msg in messages {
    match msg {
      SystemMessage(content~) =>
        for block in content {
          system.push(block)
        }
      _ => rest.push(msg)
    }
  }
  (system, rest)
}
