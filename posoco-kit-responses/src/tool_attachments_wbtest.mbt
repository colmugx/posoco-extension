// fold_tool_attachments (responses family): attachments leave the
// function_call_output string and re-enter as one synthetic user item with
// input_image parts, or degrade to explicit placeholders.

///|
fn ratt_tool_msg(outcome : @posoco.ToolOutcome) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("c1"),
    tool_name=@posoco.ToolName::unchecked("snap"),
    outcome~,
  )
}

///|
test "responses fold: vision path emits tool output then synthetic user" {
  let messages = [
    ratt_tool_msg(
      @posoco.ToolOutcome::SuccessWithAttachments(
        content="captured",
        structured=None,
        attachments=[
          @posoco.Content::Image(media_type="image/png", data="aGVsbG8="),
        ],
      ),
    ),
  ]
  let folded = fold_tool_attachments(messages, true)
  inspect(folded.length(), content="2")
  match folded[1] {
    @posoco.Message::UserMessage(content~) => {
      // message_to_responses_items renders the blocks as input parts.
      let items = message_to_responses_items(
        @posoco.Message::UserMessage(content~),
      )
      inspect(items.length(), content="1")
      let item = items[0].stringify()
      assert_true(item.contains("input_image"))
      assert_true(item.contains("data:image/png;base64,aGVsbG8="))
    }
    _ => fail("expected a synthetic user message")
  }
}

///|
test "responses fold: non-vision path degrades to the placeholder text" {
  let messages = [
    ratt_tool_msg(
      @posoco.ToolOutcome::SuccessWithAttachments(
        content="captured",
        structured=None,
        attachments=[
          @posoco.Content::Image(media_type="image/png", data="aGVsbG8="),
        ],
      ),
    ),
  ]
  let folded = fold_tool_attachments(messages, false)
  inspect(folded.length(), content="1")
  let items = message_to_responses_items(folded[0])
  let output = items[0].stringify()
  assert_true(output.contains("captured"))
  assert_true(
    output.contains("omitted: this model does not accept image input"),
  )
}
