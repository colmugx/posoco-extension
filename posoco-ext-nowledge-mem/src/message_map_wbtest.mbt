///|
fn repeat_text(unit : String, count : Int) -> String {
  let builder = StringBuilder()
  for _i in 0..<count {
    builder.write_string(unit)
  }
  builder.to_string()
}

///|
fn no_env(_name : String) -> String? {
  None
}

///|
fn plain_config() -> NmemConfig {
  NmemConfig::resolve(no_env, None, source_app="posoco")
}

///|
fn user_message(parts : Array[@posoco.Content]) -> @posoco.Message {
  @posoco.Message::UserMessage(content=parts)
}

///|
fn assistant_message(
  parts : Array[@posoco.Content],
  tool_calls : Array[@posoco.ToolCall],
) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=parts,
    tool_calls~,
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
fn assistant_with_reasoning() -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some({ content: "secret thought", raw: None, }),
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
fn tool_message(outcome : @posoco.ToolOutcome) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_1"),
    tool_name=@posoco.ToolName::unchecked("grep"),
    outcome~,
  )
}

///|
fn named_tool_call(name : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::null(),
  }
}

///|
test "map_messages: user message joins text parts with newline" {
  let messages = map_messages(
    [
      user_message([
        @posoco.Content::Text("hello"),
        @posoco.Content::Text("world"),
      ]),
    ],
    config=plain_config(),
    session_id="session_1",
  )
  guard messages is [first] else { fail("expected exactly one message") }
  debug_inspect(first.role, content="User")
  inspect(first.content, content="hello\nworld")
}

///|
test "map_messages: image parts become [Image] placeholders" {
  let messages = map_messages(
    [
      user_message([
        @posoco.Content::Text("look"),
        @posoco.Content::Image(media_type="image/png", data="zzz"),
      ]),
    ],
    config=plain_config(),
    session_id="session_1",
  )
  guard messages is [first] else { fail("expected exactly one message") }
  inspect(first.content, content="look\n[Image]")
}

///|
test "map_messages: assistant text plus one [Tool: name] line per call" {
  let messages = map_messages(
    [
      assistant_message([@posoco.Content::Text("running")], [
        named_tool_call("bash"),
        named_tool_call("grep"),
      ]),
    ],
    config=plain_config(),
    session_id="session_1",
  )
  guard messages is [first] else { fail("expected exactly one message") }
  debug_inspect(first.role, content="Assistant")
  inspect(first.content, content="running\n[Tool: bash]\n[Tool: grep]")
}

///|
test "map_messages: assistant with only tool calls keeps tool lines" {
  let messages = map_messages(
    [assistant_message([], [named_tool_call("bash")])],
    config=plain_config(),
    session_id="session_1",
  )
  guard messages is [first] else { fail("expected exactly one message") }
  inspect(first.content, content="[Tool: bash]")
}

///|
test "map_messages: reasoning is not synced" {
  let messages = map_messages(
    [assistant_with_reasoning()],
    config=plain_config(),
    session_id="session_1",
  )
  guard messages is [first] else { fail("expected exactly one message") }
  inspect(first.content, content="answer")
}

///|
test "map_messages: ToolMessage outcomes map to assistant model-visible text" {
  let messages = map_messages(
    [
      tool_message(
        @posoco.ToolOutcome::Success(content="42 matches", structured=None),
      ),
      tool_message(
        @posoco.ToolOutcome::ToolReportedError(
          content="boom: not found",
          structured=None,
        ),
      ),
      tool_message(
        @posoco.ToolOutcome::RuntimeFailure(
          error_category="timeout",
          message="timed out after 1s",
        ),
      ),
      tool_message(
        @posoco.ToolOutcome::NotExecuted(
          reason=@posoco.NotExecutedReason::RejectedByHook(
            reason="use grep instead",
          ),
          original_call_id=@posoco.CallId::unchecked("call_1"),
        ),
      ),
    ],
    config=plain_config(),
    session_id="session_1",
  )
  inspect(messages.length(), content="4")
  debug_inspect(messages[0].role, content="Assistant")
  inspect(messages[0].content, content="42 matches")
  inspect(messages[1].content, content="boom: not found")
  inspect(messages[2].content, content="timed out after 1s")
  inspect(messages[3].content, content="RejectedByHook(use grep instead)")
}

///|
test "map_messages: SystemMessage is skipped" {
  let messages = map_messages(
    [
      @posoco.Message::SystemMessage(content=[
        @posoco.Content::Text("You are an agent."),
      ]),
      user_message([@posoco.Content::Text("hi")]),
    ],
    config=plain_config(),
    session_id="session_1",
  )
  inspect(messages.length(), content="1")
  inspect(messages[0].content, content="hi")
}

///|
test "map_messages: whitespace-only messages are dropped" {
  let messages = map_messages(
    [
      user_message([@posoco.Content::Text("   ")]),
      user_message([@posoco.Content::Text("")]),
      user_message([]),
    ],
    config=plain_config(),
    session_id="session_1",
  )
  inspect(messages.length(), content="0")
}

///|
test "map_messages: external_id keeps the original input index across skipped entries" {
  let messages = map_messages(
    [
      // index 0: system, skipped
      @posoco.Message::SystemMessage(content=[@posoco.Content::Text("system")]),
      // index 1: mapped
      user_message([@posoco.Content::Text("hi")]),
      // index 2: mapped
      tool_message(@posoco.ToolOutcome::Success(content="ok", structured=None)),
      // index 3: whitespace, dropped
      user_message([@posoco.Content::Text("   ")]),
      // index 4: mapped
      user_message([@posoco.Content::Text("again")]),
    ],
    config=plain_config(),
    session_id="session_9",
  )
  inspect(messages.length(), content="3")
  inspect(
    messages[0].metadata["external_id"].stringify(),
    content="\"posoco-session_9-1\"",
  )
  inspect(
    messages[1].metadata["external_id"].stringify(),
    content="\"posoco-session_9-2\"",
  )
  inspect(
    messages[2].metadata["external_id"].stringify(),
    content="\"posoco-session_9-4\"",
  )
  inspect(messages[0].metadata["source_app"].stringify(), content="\"posoco\"")
}

///|
test "map_messages: external_id carries the configured source_app" {
  let config = NmemConfig::resolve(
    env_of([("NMEM_PLUGIN_SOURCE_APP", "demo")]),
    None,
    source_app="cetas",
  )
  let messages = map_messages(
    [user_message([@posoco.Content::Text("hi")])],
    config~,
    session_id="session_1",
  )
  inspect(
    messages[0].metadata["external_id"].stringify(),
    content="\"demo-session_1-0\"",
  )
  inspect(messages[0].metadata["source_app"].stringify(), content="\"demo\"")
}

///|
test "map_messages: over-long content is truncated with the marker" {
  let long = repeat_text("x", 25000)
  let messages = map_messages(
    [user_message([@posoco.Content::Text(long)])],
    config=plain_config(),
    session_id="session_1",
  )
  guard messages is [first] else { fail("expected exactly one message") }
  // 20000 kept + "\n\n" + 49-char marker
  inspect(first.content.length(), content="20051")
  let marker_len = 49
  let tail = first.content[first.content.length() - marker_len:].to_owned()
  inspect(tail, content="[Posoco message truncated by Nowledge Mem plugin]")
}

///|
test "map_messages: content at exactly the limit is not truncated" {
  let exact = repeat_text("y", 20000)
  let messages = map_messages(
    [user_message([@posoco.Content::Text(exact)])],
    config=plain_config(),
    session_id="session_1",
  )
  guard messages is [first] else { fail("expected exactly one message") }
  inspect(first.content.length(), content="20000")
}
