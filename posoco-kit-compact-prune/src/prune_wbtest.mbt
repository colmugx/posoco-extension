///|
fn tk_user(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
fn tk_tool(name : String, content : String) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_" + name),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=@posoco.ToolOutcome::Success(content~, structured=None),
  )
}

///|
fn tk_tool_error(name : String, content : String) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_" + name),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=@posoco.ToolOutcome::ToolReportedError(content~, structured=None),
  )
}

///|
fn tk_tool_runtime(name : String, message : String) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_" + name),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=@posoco.ToolOutcome::RuntimeFailure(error_category="tool", message~),
  )
}

///|
fn tk_tool_not_executed(name : String) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_" + name),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=@posoco.ToolOutcome::NotExecuted(
      reason=@posoco.NotExecutedReason::UnknownTool,
      original_call_id=@posoco.CallId::unchecked("call_" + name),
    ),
  )
}

///|
/// "abcd" repeated n times: exactly 4n chars = exactly n estimated tokens.
fn tk_big_tokens(n : Int) -> String {
  let sb = StringBuilder()
  for _ in 0..<n {
    sb.write_string("abcd")
  }
  sb.to_string()
}

///|
/// Assert that the message at `index` is a Success ToolMessage whose content
/// equals `expected`, keeping call id and tool name from `name`.
fn tk_assert_cleared(
  messages : Array[@posoco.Message],
  index : Int,
  name : String,
  expected : String,
) -> Unit raise {
  match messages[index] {
    @posoco.Message::ToolMessage(call_id~, tool_name~, outcome~) => {
      assert_true(call_id == @posoco.CallId::unchecked("call_" + name))
      assert_true(tool_name == @posoco.ToolName::unchecked(name))
      match outcome {
        @posoco.ToolOutcome::Success(content~, structured~) => {
          inspect(content, content=expected)
          assert_true(structured is None)
        }
        _ => fail("expected Success outcome")
      }
    }
    _ => fail("expected ToolMessage at index \{index}")
  }
}

///|
test "estimate_tokens rounds characters over four up" {
  inspect(estimate_tokens(""), content="0")
  inspect(estimate_tokens("ab"), content="1")
  inspect(estimate_tokens("abcd"), content="1")
  inspect(estimate_tokens("abcde"), content="2")
  inspect(estimate_tokens("abcdefghi"), content="3")
}

///|
test "eligible outputs summing exactly to the default budget are kept" {
  let messages = [
    tk_user("turn one"),
    tk_tool("alpha", tk_big_tokens(20000)),
    tk_tool("beta", tk_big_tokens(20000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result = prune_tool_outputs(messages)
  assert_true(result.action == Noop)
  inspect(result.pruned_tokens, content="0")
  inspect(result.pruned_count, content="0")
  assert_true(result.messages[1] == messages[1])
  assert_true(result.messages[2] == messages[2])
}

///|
test "default params clear the older output once the budget is exceeded" {
  let messages = [
    tk_user("turn one"),
    tk_tool("alpha", tk_big_tokens(25000)),
    tk_tool("beta", tk_big_tokens(20000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result = prune_tool_outputs(messages)
  assert_true(result.action == Pruned)
  inspect(result.pruned_tokens, content="25000")
  inspect(result.pruned_count, content="1")
  // beta is the newest eligible output: 20000 <= 40000, so it stays.
  assert_true(result.messages[2] == messages[2])
  tk_assert_cleared(
    result.messages,
    1,
    "alpha",
    "[Old tool result content cleared]",
  )
}

///|
test "clearing continues across every older eligible output after the budget is exceeded" {
  // head keeps the total at 35000; tail_big crosses it (55000) and tail_small
  // (56000) is cleared too, even though it alone would fit the budget.
  let messages = [
    tk_user("turn one"),
    tk_tool("tail_small", tk_big_tokens(1000)),
    tk_tool("tail_big", tk_big_tokens(20000)),
    tk_tool("head", tk_big_tokens(35000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result = prune_tool_outputs(messages)
  assert_true(result.action == Pruned)
  inspect(result.pruned_tokens, content="21000")
  inspect(result.pruned_count, content="2")
  assert_true(result.messages[3] == messages[3])
  tk_assert_cleared(
    result.messages,
    1,
    "tail_small",
    "[Old tool result content cleared]",
  )
  tk_assert_cleared(
    result.messages,
    2,
    "tail_big",
    "[Old tool result content cleared]",
  )
}

///|
test "outputs inside the two most recent user turns are never touched" {
  let messages = [
    tk_user("turn one"),
    tk_tool("old_pruned", tk_big_tokens(25000)),
    tk_tool("old_kept", tk_big_tokens(39000)),
    tk_user("turn two"),
    tk_tool("mid", tk_big_tokens(50000)),
    tk_user("turn three"),
    tk_tool("recent", tk_big_tokens(50000)),
  ]
  let result = prune_tool_outputs(messages)
  assert_true(result.action == Pruned)
  inspect(result.pruned_tokens, content="25000")
  inspect(result.pruned_count, content="1")
  assert_true(result.messages[2] == messages[2])
  assert_true(result.messages[4] == messages[4])
  assert_true(result.messages[6] == messages[6])
  tk_assert_cleared(
    result.messages,
    1,
    "old_pruned",
    "[Old tool result content cleared]",
  )
}

///|
test "protected outputs do not spend the protect budget" {
  // mid/recent sit in the two most recent user turns; their size must not
  // push `old` (30000 tokens, within the 40000 budget) into the prunable set.
  let messages = [
    tk_user("turn one"),
    tk_tool("old", tk_big_tokens(30000)),
    tk_user("turn two"),
    tk_tool("mid", tk_big_tokens(35000)),
    tk_user("turn three"),
    tk_tool("recent", tk_big_tokens(35000)),
  ]
  let result = prune_tool_outputs(messages)
  assert_true(result.action == Noop)
  assert_true(result.messages[1] == messages[1])
}

///|
test "protected tools are exempt from pruning" {
  let messages = [
    tk_user("turn one"),
    tk_tool("skill", tk_big_tokens(50000)),
    tk_tool("read", tk_big_tokens(50000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result = prune_tool_outputs(messages, protected_tools=["skill"])
  assert_true(result.action == Pruned)
  inspect(result.pruned_tokens, content="50000")
  inspect(result.pruned_count, content="1")
  assert_true(result.messages[1] == messages[1])
  tk_assert_cleared(
    result.messages,
    2,
    "read",
    "[Old tool result content cleared]",
  )
}

///|
test "protected tools do not spend the protect budget" {
  // skill is exempt; its 35000 tokens must not push `old` (25000, within
  // the 40000 budget) into the prunable set.
  let messages = [
    tk_user("turn one"),
    tk_tool("old", tk_big_tokens(25000)),
    tk_tool("skill", tk_big_tokens(35000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result = prune_tool_outputs(messages, protected_tools=["skill"])
  assert_true(result.action == Noop)
  inspect(result.pruned_count, content="0")
  assert_true(result.messages[1] == messages[1])
  assert_true(result.messages[2] == messages[2])
}

///|
test "gain equal to min_gain is a noop, just above prunes" {
  let at_limit = [
    tk_user("turn one"),
    tk_tool("alpha", tk_big_tokens(20000)),
    tk_tool("bravo", tk_big_tokens(21000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result = prune_tool_outputs(at_limit)
  assert_true(result.action == Noop)
  inspect(result.pruned_tokens, content="0")
  inspect(result.pruned_count, content="0")
  let over_limit = [
    tk_user("turn one"),
    tk_tool("alpha", tk_big_tokens(20001)),
    tk_tool("bravo", tk_big_tokens(21000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result2 = prune_tool_outputs(over_limit)
  assert_true(result2.action == Pruned)
  inspect(result2.pruned_tokens, content="20001")
  inspect(result2.pruned_count, content="1")
  assert_true(result2.messages[2] == over_limit[2])
  tk_assert_cleared(
    result2.messages,
    1,
    "alpha",
    "[Old tool result content cleared]",
  )
}

///|
test "failed and not-executed outcomes are never pruned" {
  let messages = [
    tk_user("turn one"),
    tk_tool_error("errored", tk_big_tokens(50000)),
    tk_tool_runtime("runtime", tk_big_tokens(50000)),
    tk_tool_not_executed("skipped"),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result = prune_tool_outputs(messages)
  assert_true(result.action == Noop)
  inspect(result.pruned_count, content="0")
  for i in 1..<4 {
    assert_true(result.messages[i] == messages[i])
  }
}

///|
test "mixed transcript prunes only completed successes" {
  let messages = [
    tk_user("turn one"),
    tk_tool_error("errored", tk_big_tokens(50000)),
    tk_tool("mixed", tk_big_tokens(50000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result = prune_tool_outputs(messages)
  assert_true(result.action == Pruned)
  inspect(result.pruned_tokens, content="50000")
  inspect(result.pruned_count, content="1")
  assert_true(result.messages[1] == messages[1])
  tk_assert_cleared(
    result.messages,
    2,
    "mixed",
    "[Old tool result content cleared]",
  )
}

///|
test "fewer than two user turns protects every output" {
  let single_turn = [
    tk_tool("old", tk_big_tokens(90000)),
    tk_user("only turn"),
    tk_tool("recent", tk_big_tokens(90000)),
  ]
  let result = prune_tool_outputs(single_turn)
  assert_true(result.action == Noop)
  assert_true(result.messages[0] == single_turn[0])
  assert_true(result.messages[2] == single_turn[2])
  let no_users = [tk_tool("old", tk_big_tokens(90000))]
  let result2 = prune_tool_outputs(no_users)
  assert_true(result.action == Noop)
  assert_true(result2.messages[0] == no_users[0])
}

///|
test "empty transcript is a noop copy" {
  let empty : Array[@posoco.Message] = []
  let result = prune_tool_outputs(empty)
  assert_true(result.action == Noop)
  inspect(result.messages.length(), content="0")
}

///|
test "placeholder is configurable" {
  let messages = [
    tk_user("turn one"),
    tk_tool("alpha", tk_big_tokens(50000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let result = prune_tool_outputs(messages, placeholder="cleared")
  assert_true(result.action == Pruned)
  tk_assert_cleared(result.messages, 1, "alpha", "cleared")
}

///|
test "input array is never mutated" {
  let original = [
    tk_user("turn one"),
    tk_tool("alpha", tk_big_tokens(50000)),
    tk_tool("beta", tk_big_tokens(30000)),
    tk_user("turn two"),
    tk_user("turn three"),
  ]
  let snapshot = copy_messages(original)
  let result = prune_tool_outputs(original)
  assert_true(result.action == Pruned)
  assert_false(physical_equal(result.messages, original))
  inspect(original.length(), content="5")
  for i in 0..<original.length() {
    assert_true(original[i] == snapshot[i])
  }
}
