///|
/// Tests for posoco_ext_goal.

///|
/// ModelPort fake. M3.7: `chat` returns `ModelCallResult` (the canonical
/// completion + processed_messages bundle), takes an extra `stream` argument,
/// and the trait now also requires `compact` and `provider_config`.
struct MockModelPort {
  responses : Array[@posoco.ModelCallResult]
  mut index : Int
  received_messages : Array[Array[@posoco.Message]]
}

///|
pub impl @posoco.ModelPort for MockModelPort with fn chat(
  self : MockModelPort,
  _scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.received_messages.push(messages)
  if self.index < self.responses.length() {
    let resp = self.responses[self.index]
    self.index = self.index + 1
    resp
  } else {
    // Synthesise a "mock done" stop response with no tool calls.
    let completion : @posoco.Completion = @posoco.Completion(
      content=[@posoco.Content::Text("mock done")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
      usage=None,
    )
    { completion, processed_messages: [] }
  }
}

///|
pub impl @posoco.ModelPort for MockModelPort with fn compact(
  _self : MockModelPort,
  _scope : @posoco.InvocationScope,
  _messages : Array[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "MockModelPort does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for MockModelPort with fn provider_config(
  _self : MockModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
struct MockSessionStore {
  store : Map[String, @posoco.Session]
}

///|
pub impl @posoco.SessionStore for MockSessionStore with fn load(
  self : MockSessionStore,
  id : String,
) -> @posoco.Session raise @posoco.SessionError {
  match self.store.get(id) {
    Some(s) => s
    None => { messages: [], metadata: Map::from_array([]) }
  }
}

///|
pub impl @posoco.SessionStore for MockSessionStore with fn save(
  self : MockSessionStore,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  self.store[id] = session
}

///|
/// Build a ModelCallResult whose completion is a stop-finish text response
/// with no tool calls and no usage.
fn make_stop_response(text : String) -> @posoco.ModelCallResult {
  let completion : @posoco.Completion = @posoco.Completion(
    content=[@posoco.Content::Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  { completion, processed_messages: [] }
}

///|
/// Build a ModelCallResult whose completion reports a token usage total.
fn make_stop_response_with_usage(
  text : String,
  total_tokens : Int,
) -> @posoco.ModelCallResult {
  let completion : @posoco.Completion = @posoco.Completion(
    content=[@posoco.Content::Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=Some({
      input_tokens: Some(total_tokens / 2),
      output_tokens: Some(total_tokens / 2),
      total_tokens: Some(total_tokens),
      cached_input_tokens: None,
      uncached_input_tokens: None,
    }),
  )
  { completion, processed_messages: [] }
}

///|
fn make_config() -> @posoco.AgentConfig {
  {
    max_tool_rounds: Some(5),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
    compact_threshold: None,
  }
}

///|
fn build_agent_with_goal(
  model : MockModelPort,
  goal_runner : GoalRunner,
) -> @posoco.Agent {
  @posoco.Agent(
    exts=[
      @posoco.ManifestOnly::ManifestOnly({
        id: "model",
        models: [model],
        tools: [],
        sessions: [],
        observers: [],
        hooks: [],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
        requires: [],
      }),
      @posoco.ManifestOnly::ManifestOnly({
        id: "goal",
        models: [],
        tools: [],
        sessions: [MockSessionStore::{ store: Map::from_array([]) }],
        observers: [goal_runner],
        hooks: [goal_runner],
        memory: [],
        lifecycle: [],
        commands: [],
        ui: [],
        prompt_contributors: [],
        requires: [],
      }),
    ],
    config=make_config(),
  ) catch {
    e => abort("Agent failed: \{e}")
  }
}

///|
async test "goal_injects_system_prompt" {
  let runner = GoalRunner(default_options("fix the bug"))
  let model = MockModelPort::{
    responses: [make_stop_response("done")],
    index: 0,
    received_messages: [],
  }
  let agent = build_agent_with_goal(model, runner)
  runner.status = Running

  let input : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("start"),
  ])
  ignore(agent.run_turn(input, "s1"))

  // The mock model should have received messages starting with a system message.
  assert_true(model.received_messages.length() > 0)
  let msgs = model.received_messages[0]
  assert_true(msgs.length() > 0)
  match msgs[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content {
        [@posoco.Content::Text(t), ..] => assert_true(t.contains("fix the bug"))
        _ => fail("system message should have text content")
      }
    _ => fail("first message should be system prompt")
  }
}

///|
async test "goal_detects_completion" {
  let runner = GoalRunner(default_options("fix the bug"))
  runner.status = Running
  let resp = make_stop_response("All done! [goal:complete]")

  // Simulate the model-completed stage via on_post_event.
  runner.on_post_event(
    @posoco.HookStage::ModelCompleted(completion=resp.completion),
  )
  match runner.status() {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
}

///|
async test "goal_detects_blocked" {
  let runner = GoalRunner(default_options("fix the bug"))
  runner.status = Running
  let resp = make_stop_response("Need API key from user\n[goal:blocked]")

  runner.on_post_event(
    @posoco.HookStage::ModelCompleted(completion=resp.completion),
  )
  match runner.status() {
    Blocked(reason) => assert_true(reason.contains("Need API key"))
    other => fail("expected Blocked, got \{other}")
  }
}

///|
test "observer_accumulates_usage" {
  let runner = GoalRunner(default_options("test goal"))
  assert_eq(runner.usage.total_tokens, 0)
  assert_eq(runner.usage.turns, 0)

  runner.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.Message::AssistantMessage(
        content=[@posoco.Content::Text("hi")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@posoco.FinishReason::Stop,
      ),
      usage=Some({
        input_tokens: Some(100),
        output_tokens: Some(50),
        total_tokens: Some(150),
        cached_input_tokens: None,
        uncached_input_tokens: None,
      }),
    ),
  )
  assert_eq(runner.usage.total_tokens, 150)

  runner.on_event(@posoco.TurnEvent::TurnCompleted)
  assert_eq(runner.usage.turns, 1)
}

///|
async test "execute_completes_on_marker" {
  let runner = GoalRunner(default_options("write hello world"))
  let model = MockModelPort::{
    responses: [
      make_stop_response("Working on it..."),
      make_stop_response("Almost there..."),
      make_stop_response("Done! [goal:complete]"),
    ],
    index: 0,
    received_messages: [],
  }
  let agent = build_agent_with_goal(model, runner)

  let result = runner.execute(agent, "s1") catch {
    e => fail("execute should not raise: \{e}")
  }

  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  assert_eq(result.turns_completed, 3)
  assert_true(result.history.length() == 3)
}

///|
async test "execute_stops_on_budget" {
  let options = default_options("limited goal")
  options.budget.max_turns = 2
  let runner = GoalRunner(options)
  let model = MockModelPort::{
    responses: [
      make_stop_response("step 1"),
      make_stop_response("step 2"),
      make_stop_response("step 3"),
    ],
    index: 0,
    received_messages: [],
  }
  let agent = build_agent_with_goal(model, runner)

  let result = runner.execute(agent, "s1") catch {
    e => fail("execute should not raise: \{e}")
  }

  match result.final_status {
    BudgetExhausted => ()
    other => fail("expected BudgetExhausted, got \{other}")
  }
  assert_true(result.turns_completed <= 2)
}

///|
async test "execute_sends_wrapup" {
  let options = default_options("wrapup goal")
  options.budget.max_total_tokens = 100
  options.wrapup_ratio = 0.5
  let runner = GoalRunner(options)
  // First response uses 80 tokens (>= 50% of 100), triggering wrap-up.
  let model = MockModelPort::{
    responses: [
      make_stop_response_with_usage("step 1", 80),
      make_stop_response("[goal:complete]"),
    ],
    index: 0,
    received_messages: [],
  }
  let agent = build_agent_with_goal(model, runner)

  let result = runner.execute(agent, "s1") catch {
    e => fail("execute should not raise: \{e}")
  }

  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  assert_true(runner.wrapup_sent)
}

///|
test "pause_and_resume" {
  let runner = GoalRunner(default_options("test"))
  runner.status = Running
  assert_true(runner.status() == Running)

  runner.pause()
  match runner.status() {
    Paused => ()
    other => fail("expected Paused, got \{other}")
  }

  runner.resume_goal()
  match runner.status() {
    Running => ()
    other => fail("expected Running, got \{other}")
  }
}

///|
test "goal_clear_resets_state" {
  let runner = GoalRunner(default_options("test"))
  runner.status = Running
  runner.usage.turns = 5
  runner.usage.total_tokens = 1000
  runner.current_turn = 3

  runner.clear()

  match runner.status() {
    Idle => ()
    other => fail("expected Idle, got \{other}")
  }
  assert_eq(runner.usage.turns, 0)
  assert_eq(runner.usage.total_tokens, 0)
  assert_eq(runner.current_turn, 0)
}

///|
async test "goal_ignores_non_running_status" {
  let runner = GoalRunner(default_options("test"))
  runner.status = Paused

  // Hook::before_model should pass through without injection when not Running.
  let msgs : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hello")]),
  ]
  let returned = runner.before_model(msgs) catch {
    e => fail("before_model should not abort: \{e}")
  }
  assert_eq(returned.length(), 1)
}

///|
async test "stall_detection_pauses" {
  let options = default_options("stall test")
  options.stall_turn_threshold = 2
  options.stall_min_tokens = 50
  let runner = GoalRunner(options)
  // Responses with no usage → 0 token delta → stall.
  let model = MockModelPort::{
    responses: [
      make_stop_response("thinking..."),
      make_stop_response("still thinking"),
      make_stop_response("more thinking"),
    ],
    index: 0,
    received_messages: [],
  }
  let agent = build_agent_with_goal(model, runner)

  let result = runner.execute(agent, "s1") catch {
    e => fail("execute should not raise: \{e}")
  }

  match result.final_status {
    Paused => ()
    other => fail("expected Paused (stall), got \{other}")
  }
}
