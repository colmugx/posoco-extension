///|
/// Prefix-stability rules and the bounded-recovery predicate.

///|
fn user_turn(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
fn tool_call_message(path : String) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("unique-id"),
        name: @posoco.ToolName::unchecked("read_file"),
        arguments: Json::object({ "path": Json::string(path) }),
      },
    ],
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
}

///|
fn work_tool(name : String, description : String) -> @posoco.ToolDef {
  @posoco.ToolDef::ToolDef(
    name=@posoco.ToolName::unchecked(name),
    description~,
    input_schema=Json::object(Map::from_array([])),
    owner=@posoco.OwnerId::unchecked("test"),
    policy=@posoco.ExecutionPolicy::Sequential,
    provenance=None,
  )
}

///|
test "the cycle detector needs three identical calls in one user turn" {
  let a = tool_call_message("/tmp/a")
  let b = tool_call_message("/tmp/b")
  assert_false(repeated_tool_calls([user_turn("read"), a, a]))
  assert_true(repeated_tool_calls([user_turn("read"), a, a, a]))
  assert_false(repeated_tool_calls([user_turn("read"), a, b, a]))
  // A new user turn resets the streak.
  assert_false(repeated_tool_calls([a, a, user_turn("new"), a]))
}

///|
test "canonical tool order makes equal tool sets share one prefix" {
  let read = work_tool("read_file", "read a file")
  let write = work_tool("write_file", "write a file")
  let forward = canonical_tool_order([read, write])
  let reversed = canonical_tool_order([write, read])
  assert_eq(
    Json::array(forward.map(fn(t) { t.input_schema })).stringify(),
    Json::array(reversed.map(fn(t) { t.input_schema })).stringify(),
  )
  assert_eq(forward[0].name.to_string(), "read_file")
  assert_eq(forward[1].name.to_string(), "write_file")
  assert_eq(reversed[0].name.to_string(), "read_file")
}

///|
test "canonical tool order never mutates the caller's array" {
  let read = work_tool("read_file", "read a file")
  let write = work_tool("write_file", "write a file")
  let input = [write, read]
  ignore(canonical_tool_order(input))
  assert_eq(input[0].name.to_string(), "write_file")
  assert_eq(input[1].name.to_string(), "read_file")
}

///|
fn completion_with(
  finish_reason : @posoco.FinishReason,
  content : Array[@posoco.Content],
  tool_calls : Array[@posoco.ToolCall],
) -> @posoco.Completion {
  @posoco.Completion::Completion(
    content~,
    tool_calls~,
    reasoning=None,
    finish_reason~,
    usage=None,
  )
}

///|
test "only an unusable length cutoff is safe to retry" {
  let exhausted = completion_with(@posoco.FinishReason::Length, [], [])
  assert_true(can_retry_reasoning_exhaustion(exhausted))
  let partial = completion_with(
    @posoco.FinishReason::Length,
    [@posoco.Content::Text("partial answer")],
    [],
  )
  assert_false(can_retry_reasoning_exhaustion(partial))
  let stopped = completion_with(
    @posoco.FinishReason::Stop,
    [@posoco.Content::Text("answer")],
    [],
  )
  assert_false(can_retry_reasoning_exhaustion(stopped))
  let actionable = completion_with(@posoco.FinishReason::Length, [], [
    {
      call_id: @posoco.CallId::unchecked("id"),
      name: @posoco.ToolName::unchecked("read_file"),
      arguments: Json::object(Map::from_array([])),
    },
  ])
  assert_false(can_retry_reasoning_exhaustion(actionable))
}
