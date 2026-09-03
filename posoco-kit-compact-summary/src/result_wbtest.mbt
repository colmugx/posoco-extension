///|
test "replace result heads with the summary anchor and keeps the tail" {
  let tail = [user_msg("latest question"), tool_result("read", "out")]
  let result = build_replace_result("we were fixing the parser", tail)
  assert_eq(result.compacted_messages.length(), 3)
  match result.mode {
    Replace => ()
    _ => fail("expected Replace mode")
  }
  let head = text_of(result.compacted_messages[0])
  assert_true(head.has_prefix(SUMMARY_PREFIX))
  assert_true(head.contains("\n\nwe were fixing the parser"))
  // Tail entries are carried over intact (structural equality).
  assert_true(result.compacted_messages[1] == tail[0])
  assert_true(result.compacted_messages[2] == tail[1])
  // Input tail is not mutated or consumed.
  assert_eq(tail.length(), 2)
}

///|
test "summary message produced here is recognized by its prefix" {
  let result = build_replace_result("summary body", [])
  assert_eq(result.compacted_messages.length(), 1)
  assert_true(is_summary_message(result.compacted_messages[0]))
}

///|
test "ordinary messages are not summary messages" {
  assert_false(
    is_summary_message(user_msg("Previous context has been compacted? nope")),
  )
  assert_false(
    is_summary_message(asst_msg("Previous context has been compacted.", [])),
  )
  assert_false(is_summary_message(tool_result("read", "x")))
  assert_false(is_summary_message(UserMessage(content=[Text("unrelated")])))
  // The exact prefix alone counts.
  assert_true(is_summary_message(user_msg(SUMMARY_PREFIX)))
  // First Text block decides, even when preceded by an image.
  assert_true(
    is_summary_message(
      UserMessage(content=[
        Image(media_type="image/png", data="Zm9v"),
        Text(SUMMARY_PREFIX + "\n\nbody"),
      ]),
    ),
  )
}
