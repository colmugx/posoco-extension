///|
/// content_encoding.mbt — Shared chat-completions content-block encoding for
/// the delegating adapters (openai-compatible, deepseek, kimi, zai,
/// openrouter).
///
/// Chat-completions `content` accepts either a plain string or a typed parts
/// array. Some compatible servers reject arrays, so the string form stays the
/// default; the parts form is used only when image blocks are present AND the
/// selected model accepts image input. An image that cannot be sent is never
/// dropped silently: it downgrades to an explicit placeholder so the model
/// knows an image exists that it cannot see.

///|
/// Result of encoding one message's content blocks.
pub(all) enum EncodedChatContent {
  /// Plain string form: no image blocks were present, or every image was
  /// downgraded to a placeholder appended to the text.
  TextContent(String)
  /// Typed parts form for image-capable models: one `text` part per Text
  /// block, one `image_url` part per Image block.
  PartsContent(Array[Json])
}

///|
/// Wire form of an Image block's payload. Kernel `Content::Image` data is
/// opaque: adapters may receive base64 or an http(s) URL; both pass through
/// as `image_url.url` in the shape chat-completions endpoints expect.
fn image_url_for(media_type : String, data : String) -> String {
  if data.has_prefix("https://") || data.has_prefix("http://") {
    data
  } else {
    "data:" + media_type + ";base64," + data
  }
}

///|
/// Placeholder for an image the endpoint cannot accept. The size is the
/// decoded-byte estimate (base64 length × 3/4) so the model can gauge how
/// much was attached without seeing it.
fn image_placeholder(media_type : String, data : String) -> String {
  let approx_kb = data.length() * 3 / 4096
  "[Attached " +
  media_type +
  ", ~" +
  approx_kb.to_string() +
  " KB, omitted: this model does not accept image input]"
}

///|
/// Encode content blocks for a chat-completions message `content` field.
///
/// - No image blocks → `TextContent` (concatenated text).
/// - Image blocks with `supports_images=true` → `PartsContent`.
/// - Image blocks with `supports_images=false` → `TextContent` with each
///   image downgraded to an explicit placeholder (never a silent drop).
pub fn encode_chat_message_content(
  blocks : Array[@posoco.Content],
  supports_images? : Bool = false,
) -> EncodedChatContent {
  let has_image = blocks.exists(fn(b) { b is @posoco.Content::Image(..) })
  if !has_image {
    let builder = StringBuilder()
    for block in blocks {
      match block {
        @posoco.Content::Text(s) => builder.write_string(s)
        @posoco.Content::Image(..) => ()
      }
    }
    return TextContent(builder.to_string())
  }
  if supports_images {
    let parts : Array[Json] = []
    for block in blocks {
      match block {
        @posoco.Content::Text(s) =>
          parts.push(
            Json::object(
              Map::from_array([
                ("type", Json::string("text")),
                ("text", Json::string(s)),
              ]),
            ),
          )
        @posoco.Content::Image(media_type~, data~) =>
          parts.push(
            Json::object(
              Map::from_array([
                ("type", Json::string("image_url")),
                (
                  "image_url",
                  Json::object(
                    Map::from_array([
                      ("url", Json::string(image_url_for(media_type, data))),
                    ]),
                  ),
                ),
              ]),
            ),
          )
      }
    }
    return PartsContent(parts)
  }
  let builder = StringBuilder()
  let mut wrote = false
  for block in blocks {
    match block {
      @posoco.Content::Text(s) => {
        builder.write_string(s)
        wrote = true
      }
      @posoco.Content::Image(media_type~, data~) => {
        if wrote {
          builder.write_char('\n')
        }
        builder.write_string(image_placeholder(media_type, data))
        wrote = true
      }
    }
  }
  TextContent(builder.to_string())
}
