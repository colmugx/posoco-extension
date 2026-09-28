// fold_tool_attachments: the tool role carries only a text content string on
// this protocol, so attachments either collapse into one synthetic user
// message after the tool run (image-capable models) or degrade to explicit
// placeholders (never a silent drop).

///|
fn att_tool_msg(id : String, outcome : @posoco.ToolOutcome) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked(id),
    tool_name=@posoco.ToolName::unchecked("snap"),
    outcome~,
  )
}

///|
fn att_image() -> @posoco.Content {
  @posoco.Content::Image(media_type="image/png", data="aGVsbG8=")
}

///|
test "vision fold keeps tool messages and appends one synthetic user message" {
  let messages = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("shot?")]),
    att_tool_msg(
      "c1",
      @posoco.ToolOutcome::SuccessWithAttachments(
        content="captured",
        structured=None,
        attachments=[att_image()],
      ),
    ),
    att_tool_msg(
      "c2",
      @posoco.ToolOutcome::Success(content="plain", structured=None),
    ),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("thanks")]),
  ]
  let folded = fold_tool_attachments(messages, true)
  // user, tool, tool, synthetic user (media), original user
  inspect(folded.length(), content="5")
  match folded[3] {
    @posoco.Message::UserMessage(content~) => {
      inspect(content.length(), content="2")
      assert_true(content[0] is @posoco.Content::Text(_))
      assert_true(content[1] is @posoco.Content::Image(..))
    }
    _ => fail("expected a synthetic user message after the tool run")
  }
}

///|
test "non-vision fold degrades attachments to explicit placeholders" {
  let messages = [
    att_tool_msg(
      "c1",
      @posoco.ToolOutcome::SuccessWithAttachments(
        content="captured",
        structured=None,
        attachments=[att_image()],
      ),
    ),
  ]
  let folded = fold_tool_attachments(messages, false)
  inspect(folded.length(), content="1")
  match folded[0] {
    @posoco.Message::ToolMessage(outcome=Success(content~, ..), ..) => {
      assert_true(content.contains("captured"))
      assert_true(
        content.contains(
          "[Attached image/png, ~0 KB, omitted: this model does not accept image input]",
        ),
      )
    }
    _ => fail("expected a degraded Success tool message")
  }
}

///|
test "fold without attachments is the identity" {
  let messages = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")]),
    att_tool_msg(
      "c1",
      @posoco.ToolOutcome::Success(content="ok", structured=None),
    ),
  ]
  inspect(fold_tool_attachments(messages, true).length(), content="2")
}
