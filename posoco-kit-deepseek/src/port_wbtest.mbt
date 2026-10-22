///|
/// The decorator's observable contract, proven against a recording inner port.

///|
struct RecordingPort {
  mut calls : Int32
  mut streamed : Bool
  mut last_messages : Array[@posoco.Message]
  mut last_tools : Array[@posoco.ToolDef]
  completion : @posoco.Completion
}

///|
fn recording_port(completion : @posoco.Completion) -> RecordingPort {
  { calls: 0, streamed: false, last_messages: [], last_tools: [], completion, }
}

///|
impl @posoco.ModelPort for RecordingPort with fn chat(
  self : RecordingPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.calls = self.calls + 1
  self.streamed = stream is @posoco.StreamMode::Stream(_)
  self.last_messages = messages.to_owned()
  self.last_tools = tools.copy()
  @posoco.ModelCallResult::{
    completion: self.completion,
    processed_messages: messages.to_owned(),
  }
}

///|
impl @posoco.ModelPort for RecordingPort with fn compact(
  _self : RecordingPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("recording port does not compact")
}

///|
impl @posoco.ModelPort for RecordingPort with fn provider_config(
  _self : RecordingPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=Some(1000),
    compact_threshold=None,
  )
}

///|
fn test_scope() -> @posoco.InvocationScope {
  {
    session_id: @posoco.SessionId::unchecked("session"),
    run_id: @posoco.RunId::unchecked("run"),
    effect_id: None,
    pressure: None,
  }
}

///|
fn test_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
fn stop_completion() -> @posoco.Completion {
  @posoco.Completion::Completion(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
}

///|
fn exhausted_completion() -> @posoco.Completion {
  @posoco.Completion::Completion(
    content=[],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{ content: "thinking only", raw: None, }),
    finish_reason=@posoco.FinishReason::Length,
    usage=None,
  )
}

///|
fn partial_length_completion() -> @posoco.Completion {
  @posoco.Completion::Completion(
    content=[@posoco.Content::Text("partial")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Length,
    usage=None,
  )
}

///|
async test "policy port sorts tools and appends tail guidance once" {
  let inner = recording_port(stop_completion())
  let inner_ref : &@posoco.ModelPort = inner
  let port = deepseek_policy_port(
    inner=inner_ref,
    policy=DeepSeekPolicy::default_protections(),
  )
  let read = work_tool("read_file", "read a file")
  let write = work_tool("write_file", "write a file")
  let repeated = tool_call_message("/tmp/a")
  let messages : Array[@posoco.Message] = [
    user_turn("read"),
    repeated,
    repeated,
    repeated,
  ]
  let tools = [write, read]
  ignore(
    port.chat(
      test_scope(),
      messages[:],
      tools,
      test_options(),
      @posoco.StreamMode::NoStream,
    ),
  )
  // The caller's arrays are untouched.
  assert_eq(messages.length(), 4)
  assert_eq(tools[0].name.to_string(), "write_file")
  // The inner port sees one extra, trailing system message.
  assert_eq(inner.last_messages.length(), 5)
  match inner.last_messages[4] {
    @posoco.Message::SystemMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(text) =>
          assert_eq(text, convergence_instruction())
        @posoco.Content::Image(..) => fail("guidance is text")
      }
    _ => fail("expected a trailing system message")
  }
  // Tools reach the wire in canonical order.
  assert_eq(inner.last_tools[0].name.to_string(), "read_file")
  assert_eq(inner.last_tools[1].name.to_string(), "write_file")
}

///|
async test "policy port leaves a healthy transcript alone" {
  let inner = recording_port(stop_completion())
  let inner_ref : &@posoco.ModelPort = inner
  let port = deepseek_policy_port(
    inner=inner_ref,
    policy=DeepSeekPolicy::default_protections(),
  )
  let messages : Array[@posoco.Message] = [
    user_turn("read"),
    tool_call_message("/tmp/a"),
  ]
  ignore(
    port.chat(
      test_scope(),
      messages[:],
      [],
      test_options(),
      @posoco.StreamMode::NoStream,
    ),
  )
  assert_eq(inner.last_messages.length(), 2)
  assert_eq(inner.last_tools.length(), 0)
}

///|
async test "policy port suppresses guidance where a system message is illegal" {
  let inner = recording_port(stop_completion())
  let inner_ref : &@posoco.ModelPort = inner
  let port = deepseek_policy_port(
    inner=inner_ref,
    policy=DeepSeekPolicy::default_protections(),
    inject_convergence=false,
  )
  let repeated = tool_call_message("/tmp/a")
  let messages : Array[@posoco.Message] = [
    user_turn("read"),
    repeated,
    repeated,
    repeated,
  ]
  ignore(
    port.chat(
      test_scope(),
      messages[:],
      [work_tool("read_file", "read a file")],
      test_options(),
      @posoco.StreamMode::NoStream,
    ),
  )
  assert_eq(inner.last_messages.length(), 4)
}

///|
async test "policy port retries an unusable length cutoff once at low effort" {
  let inner = recording_port(exhausted_completion())
  let inner_ref : &@posoco.ModelPort = inner
  let low = recording_port(stop_completion())
  let retry : (() -> &@posoco.ModelPort)? = Some(fn() {
    let borrowed : &@posoco.ModelPort = low
    borrowed
  })
  let port = deepseek_policy_port(
    inner=inner_ref,
    policy=DeepSeekPolicy::default_protections(),
    retry_at_low=retry,
  )
  let result = port.chat(
    test_scope(),
    [user_turn("think")][:],
    [],
    test_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(inner.calls, 1)
  assert_eq(low.calls, 1)
  assert_eq(result.completion.finish_reason(), @posoco.FinishReason::Stop)
}

///|
async test "policy port never replays a partial answer" {
  let inner = recording_port(partial_length_completion())
  let inner_ref : &@posoco.ModelPort = inner
  let low = recording_port(stop_completion())
  let retry : (() -> &@posoco.ModelPort)? = Some(fn() {
    let borrowed : &@posoco.ModelPort = low
    borrowed
  })
  let port = deepseek_policy_port(
    inner=inner_ref,
    policy=DeepSeekPolicy::default_protections(),
    retry_at_low=retry,
  )
  ignore(
    port.chat(
      test_scope(),
      [user_turn("think")][:],
      [],
      test_options(),
      @posoco.StreamMode::NoStream,
    ),
  )
  assert_eq(inner.calls, 1)
  assert_eq(low.calls, 0)
}

///|
async test "recovery opt-out keeps the first response" {
  let inner = recording_port(exhausted_completion())
  let inner_ref : &@posoco.ModelPort = inner
  let low = recording_port(stop_completion())
  let retry : (() -> &@posoco.ModelPort)? = Some(fn() {
    let borrowed : &@posoco.ModelPort = low
    borrowed
  })
  let port = deepseek_policy_port(
    inner=inner_ref,
    policy=DeepSeekPolicy(
      max_reasoning_chars=Some(120000),
      repeated_reasoning_span_chars=Some(256),
      recover_on_reasoning_exhaustion=false,
    ),
    retry_at_low=retry,
  )
  let result = port.chat(
    test_scope(),
    [user_turn("think")][:],
    [],
    test_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(low.calls, 0)
  assert_eq(result.completion.finish_reason(), @posoco.FinishReason::Length)
}

///|
async test "policy port forwards the streaming mode and provider config" {
  let inner = recording_port(stop_completion())
  let inner_ref : &@posoco.ModelPort = inner
  let port = deepseek_policy_port(
    inner=inner_ref,
    policy=DeepSeekPolicy::default_protections(),
  )
  ignore(
    port.chat(
      test_scope(),
      [user_turn("hi")][:],
      [],
      test_options(),
      @posoco.StreamMode::Stream(fn(_chunk) { () }),
    ),
  )
  assert_true(inner.streamed)
  assert_eq(port.provider_config().context_window, Some(1000))
  // Compaction is forwarded untouched.
  try
    @posoco.ModelPort::compact(
      port,
      test_scope(),
      [user_turn("hi")][:],
      [],
      test_options(),
      @posoco.CompactTrigger::Manual,
    )
  catch {
    @posoco.ModelError::ResponseParse(message) =>
      assert_eq(message, "recording port does not compact")
    error => raise error
  } noraise {
    _ => fail("expected the inner compaction error")
  }
}
