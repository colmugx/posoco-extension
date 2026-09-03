// encode_chat_message_content: three-state contract shared by every
// chat-completions adapter — string form by default, parts form for
// image-capable models, explicit placeholder downgrade otherwise.

///|
test "text-only blocks stay in the string form" {
  let blocks : Array[@posoco.Content] = [
    @posoco.Content::Text("hello "),
    @posoco.Content::Text("world"),
  ]
  match encode_chat_message_content(blocks) {
    TextContent(s) => inspect(s, content="hello world")
    _ => fail("text-only blocks must encode as TextContent")
  }
  // supports_images=true must not change text-only messages: some compatible
  // servers reject content arrays, so the string form stays the default.
  match encode_chat_message_content(blocks, supports_images=true) {
    TextContent(s) => inspect(s, content="hello world")
    _ => fail("text-only blocks must stay TextContent even with images on")
  }
}

///|
test "image blocks with supports_images encode as typed parts" {
  let blocks : Array[@posoco.Content] = [
    @posoco.Content::Text("what is this"),
    @posoco.Content::Image(media_type="image/png", data="aW1n"),
    @posoco.Content::Image(
      media_type="image/jpeg",
      data="https://example.com/pic.jpg",
    ),
  ]
  match encode_chat_message_content(blocks, supports_images=true) {
    PartsContent(parts) => {
      inspect(parts.length(), content="3")
      json_inspect(parts[0], content={ "type": "text", "text": "what is this" })
      json_inspect(parts[1], content={
        "type": "image_url",
        "image_url": { "url": "data:image/png;base64,aW1n" },
      })
      json_inspect(parts[2], content={
        "type": "image_url",
        "image_url": { "url": "https://example.com/pic.jpg" },
      })
    }
    _ => fail("image blocks with supports_images must encode as PartsContent")
  }
}

///|
test "image blocks without support downgrade to explicit placeholders" {
  let blocks : Array[@posoco.Content] = [
    @posoco.Content::Text("see"),
    @posoco.Content::Image(media_type="image/png", data="QUJD"),
  ]
  match encode_chat_message_content(blocks) {
    TextContent(s) =>
      inspect(
        s,
        content="see\n[Attached image/png, ~0 KB, omitted: this model does not accept image input]",
      )
    _ => fail("downgrade must stay in the string form")
  }
}

///|
test "image-only message without support keeps a visible placeholder" {
  let blocks : Array[@posoco.Content] = [
    @posoco.Content::Image(media_type="image/png", data="QUJD"),
  ]
  match encode_chat_message_content(blocks) {
    TextContent(s) =>
      inspect(
        s,
        content="[Attached image/png, ~0 KB, omitted: this model does not accept image input]",
      )
    _ => fail("downgrade must stay in the string form")
  }
}
