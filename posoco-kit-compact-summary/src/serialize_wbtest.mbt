///|
test "role prefixes and inline tool calls" {
  let messages = [
    system_msg("be helpful"),
    user_msg("fix the bug"),
    asst_msg("reading it", [
      tool_call("read_file", args_json([("path", "main.mbt")])),
    ]),
    tool_result("read_file", "fn main {}"),
  ]
  inspect(
    serialize_for_summary(messages),
    content=(
      #|[System]: be helpful
      #|
      #|[User]: fix the bug
      #|
      #|[Assistant]: reading it
      #|[Assistant tool call]: read_file({"path":"main.mbt"})
      #|
      #|[Tool result]: fn main {}
    ),
  )
}

///|
test "assistant with empty text renders only its tool call lines" {
  let message : @posoco.Message = AssistantMessage(
    content=[],
    tool_calls=[tool_call("bash", Json::null())],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
  inspect(
    serialize_for_summary([message]),
    content="[Assistant tool call]: bash(null)",
  )
}

///|
test "images become placeholders" {
  let message : @posoco.Message = UserMessage(content=[
    Image(media_type="image/png", data="Zm9v"),
    Text("see this"),
  ])
  inspect(
    serialize_for_summary([message]),
    content="[User]: [image: image/png] see this",
  )
}

///|
test "tool output truncates exactly at the limit" {
  let long = tool_result("read", String::make(2500, 'x'))
  let expected = "[Tool result]: " + String::make(2000, 'x') + "\n[truncated]"
  assert_eq(serialize_for_summary([long]), expected)
  // Custom limit.
  let small = tool_result("read", "abcdefghij")
  assert_eq(
    serialize_for_summary([small], tool_output_char_limit=5),
    "[Tool result]: abcde\n[truncated]",
  )
  // At exactly the limit there is no truncation.
  let exact = tool_result("read", String::make(2000, 'x'))
  assert_eq(
    serialize_for_summary([exact]),
    "[Tool result]: " + String::make(2000, 'x'),
  )
}

///|
test "error outcomes use the error prefix, not-executed stays bare" {
  let messages = [
    tool_error("write", "disk full"),
    tool_runtime_failure("write", "spawn failed"),
    tool_not_executed("write"),
  ]
  inspect(
    serialize_for_summary(messages),
    content=(
      #|[Tool error]: disk full
      #|
      #|[Tool error]: spawn failed
      #|
      #|[Tool not executed]
    ),
  )
}

///|
test "messages are joined with a blank line" {
  let text = serialize_for_summary([user_msg("a"), user_msg("b")])
  assert_eq(text, "[User]: a\n\n[User]: b")
}
