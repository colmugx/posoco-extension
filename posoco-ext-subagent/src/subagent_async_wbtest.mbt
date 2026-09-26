// ---------------------------------------------------------------------------
// End-to-end `agent` tool semantics (whitebox, async): background refusal,
// budget gate, kind lookup, whitelist intersection, prompt assembly gate,
// model resolve, skills mapping, session minting, timeout enforcement,
// terminal-state mapping, and the BridgeObserver event channel.
// ---------------------------------------------------------------------------

///|
async test "agent_happy_path_returns_child_result_with_footer" {
  let composer = FakeComposer::FakeComposer(response_text="child did the thing")
  let tools = test_tools(composer=composer as &ChildComposer)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(args_object([("task", Json::string("write the tests"))])),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.contains("child did the thing"))
      assert_true(content.contains("child_session: subagent-1"))
      assert_true(content.contains("usage: turns=1 in=0 out=0"))
      match structured {
        Some(Json::Object(fields)) =>
          match fields.get("state") {
            Some(Json::String("completed")) => ()
            _ => fail("expected structured state 'completed'")
          }
        _ => fail("expected structured payload")
      }
    }
    _ => fail("expected success outcome")
  }
  assert_eq(composer.specs.length(), 1)
  assert_eq(composer.specs[0].task, "write the tests")
  assert_eq(composer.specs[0].session_id, "subagent-1")
  assert_eq(composer.specs[0].resuming, false)
  assert_eq(composer.specs[0].slot, "parent/slot")
  assert_eq(composer.specs[0].kind_name, "coder")
  assert_true(
    composer.specs[0].mode is @permission.PermissionMode::WorkspaceWrite,
  )
  assert_true(!composer.specs[0].system_prompt.is_empty())
  assert_eq(tools.ledger.acquired().length(), 1)
}

///|
priv struct ConcurrencyProbeModel {
  entered : @async.Queue[Int]
  release : @async.Queue[Unit]
  mut active : Int
  mut peak : Int
}

///|
fn ConcurrencyProbeModel::new() -> ConcurrencyProbeModel {
  {
    entered: @async.Queue(kind=Unbounded),
    release: @async.Queue(kind=Unbounded),
    active: 0,
    peak: 0,
  }
}

///|
impl @posoco.ModelPort for ConcurrencyProbeModel with fn chat(
  self : ConcurrencyProbeModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.active = self.active + 1
  if self.active > self.peak {
    self.peak = self.active
  }
  ignore(self.entered.try_put(self.active) catch { _ => false })
  ignore(
    self.release.get() catch {
      error => raise @posoco.ModelError::ResponseParse(error.to_string())
    },
  )
  self.active = self.active - 1
  @posoco.tk_stop_response("released")
}

///|
impl @posoco.ModelPort for ConcurrencyProbeModel with fn compact(
  _self : ConcurrencyProbeModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "ConcurrencyProbeModel does not implement compact",
  )
}

///|
impl @posoco.ModelPort for ConcurrencyProbeModel with fn provider_config(
  _self : ConcurrencyProbeModel,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
async test "global_concurrency_caps_parallel_child_lifetimes" {
  let probe = ConcurrencyProbeModel::new()
  let composer = FakeComposer::FakeComposer(
    response_text="unused",
    slow_model=Some(probe as &@posoco.ModelPort),
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_global_concurrency(2),
  )
  @async.with_task_group(async fn(group) {
    let handles : Array[@async.Task[@posoco.ToolOutcome]] = []
    for task in ["one", "two", "three"] {
      handles.push(
        group.spawn(async fn() {
          @posoco.ToolProvider::execute(
            tools,
            "agent",
            agent_call(args_object([("task", Json::string(task))])),
          )
        }),
      )
    }

    ignore(probe.entered.get())
    ignore(probe.entered.get())
    assert_eq(probe.peak, 2)
    assert_eq(composer.specs.length(), 2)
    assert_true(probe.entered.try_get() is None)

    probe.release.put(())
    ignore(probe.entered.get())
    assert_eq(probe.peak, 2)
    assert_eq(composer.specs.length(), 3)

    probe.release.put(())
    probe.release.put(())
    for handle in handles {
      assert_true(handle.wait() is @posoco.ToolOutcome::Success(_))
    }
  })
  assert_eq(tools.ledger.acquired().length(), 3)
}

///|
/// Child composer that injects one composition failure while delegating every
/// other child to the ordinary real-Agent fake. This proves one failed row in
/// a parallel parent tool wave cannot poison its sibling.
priv struct SelectiveFailComposer {
  inner : FakeComposer
  fail_task : String
  mut failures : Int
}

///|
fn SelectiveFailComposer::SelectiveFailComposer(
  fail_task~ : String,
) -> SelectiveFailComposer {
  {
    inner: FakeComposer::FakeComposer(response_text="sibling child completed"),
    fail_task,
    failures: 0,
  }
}

///|
impl ChildComposer for SelectiveFailComposer with fn compose(
  self : SelectiveFailComposer,
  spec : ChildSpec,
) -> @posoco.Agent raise ComposerError {
  if spec.task == self.fail_task {
    self.failures = self.failures + 1
    raise ComposerError::Failed("injected sibling failure")
  }
  ChildComposer::compose(self.inner, spec)
}

///|
fn sibling_failure_wave() -> @posoco.ModelCallResult {
  let calls : Array[@posoco.ToolCall] = [
    {
      call_id: @posoco.CallId::unchecked("sibling-fail"),
      name: @posoco.ToolName::unchecked("agent"),
      arguments: args_object([("task", Json::string("explode"))]),
    },
    {
      call_id: @posoco.CallId::unchecked("sibling-ok"),
      name: @posoco.ToolName::unchecked("agent"),
      arguments: args_object([("task", Json::string("survive"))]),
    },
  ]
  @posoco.ModelCallResult::{
    completion: @posoco.Completion::Completion(
      content=[],
      tool_calls=calls,
      reasoning=None,
      finish_reason=@posoco.FinishReason::ToolCalls,
      usage=None,
    ),
    processed_messages: [],
  }
}

///|
async test "spawn_budget_resets_at_each_parent_run" {
  let composer = FakeComposer::FakeComposer(response_text="ok")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_spawn_budget(2),
  )
  let scope1 : @posoco.EventScope = {
    session_id: @posoco.SessionId::unchecked("parent"),
    run_id: @posoco.RunId::unchecked("run-1"),
    turn_id: @posoco.TurnId::unchecked("turn-1"),
  }
  @posoco.Observer::on_event_at(
    tools,
    Some(scope1),
    @posoco.TurnEvent::TurnStarted,
  )
  for task in ["one", "two"] {
    let outcome = @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(args_object([("task", Json::string(task))])),
    )
    assert_true(outcome is @posoco.ToolOutcome::Success(_))
  }
  assert_eq(tools.ledger.remaining(), 0)

  // Ordinary events in the same run do not replenish the budget.
  @posoco.Observer::on_event_at(
    tools,
    Some(scope1),
    @posoco.TurnEvent::TurnCompleted,
  )
  assert_eq(tools.ledger.remaining(), 0)

  let scope2 : @posoco.EventScope = {
    session_id: @posoco.SessionId::unchecked("parent"),
    run_id: @posoco.RunId::unchecked("run-2"),
    turn_id: @posoco.TurnId::unchecked("turn-2"),
  }
  @posoco.Observer::on_event_at(
    tools,
    Some(scope2),
    @posoco.TurnEvent::TurnStarted,
  )
  assert_eq(tools.ledger.remaining(), 2)
  let next = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(args_object([("task", Json::string("three"))])),
  )
  assert_true(next is @posoco.ToolOutcome::Success(_))
  assert_eq(tools.ledger.remaining(), 1)
}

///|
async test "spawn_budget_exhaustion_refuses_explicitly" {
  let composer = FakeComposer::FakeComposer(response_text="ok")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_spawn_budget(1),
  )
  let first = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(args_object([("task", Json::string("first"))])),
  )
  assert_true(first is @posoco.ToolOutcome::Success(_))
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(args_object([("task", Json::string("second"))])),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_eq(
        content, "spawn budget exhausted (1/1 used): explicit refusal — finish with the subagents you have",
      )
    _ => fail("expected explicit budget refusal")
  }
}

///|
async test "parallel_subagent_failure_does_not_poison_sibling_or_parent" {
  let composer = SelectiveFailComposer::SelectiveFailComposer(
    fail_task="explode",
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_spawn_budget(2),
  )
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(sibling_failure_wave()),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("parent recovered after sibling failure"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let result = parent.run_scoped(async fn(agent) {
    agent.run_turn(
      @posoco.tk_user_msg("run two independent children"),
      "parent_sibling_isolation",
    )
  })

  // The failed row is a tool-level terminal, not a wave-level exception:
  // the sibling child still composes and runs, and the parent reaches its
  // second model call instead of aborting the turn.
  assert_eq(model.call_count(), 2)
  assert_eq(result.final_session_id, "parent_sibling_isolation")
  match result.message {
    @posoco.Message::AssistantMessage(content=[@posoco.Content::Text(text)], ..) =>
      assert_eq(text, "parent recovered after sibling failure")
    _ => fail("expected the parent stop response")
  }
  assert_eq(composer.failures, 1)
  assert_eq(composer.inner.specs.length(), 1)
  assert_eq(composer.inner.specs[0].task, "survive")
  assert_eq(tools.background_children().length(), 1)
  match tools.registry.get(composer.inner.specs[0].session_id) {
    Some(record) =>
      match record.state {
        Done("completed", summary) =>
          assert_true(summary.contains("sibling child completed"))
        _ => fail("successful sibling must remain completed")
      }
    None => fail("successful sibling must remain registered")
  }
}

///|
async test "unknown_kind_lists_catalog_names" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("kind", Json::string("wizard")),
        ]),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("unknown kind 'wizard'"))
      assert_true(content.contains("coder"))
      assert_true(content.contains("scout"))
      assert_true(content.contains("reviewer"))
      assert_true(content.contains("oracle"))
    }
    _ => fail("expected kind error")
  }
}

///|
async test "tools_argument_intersects_kind_whitelist_both_ways" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(
      args_object([
        ("task", Json::string("t")),
        (
          "tools",
          Json::array([
            Json::string("grep"),
            Json::string("nonexistent_tool"),
            Json::string("grep"),
          ]),
        ),
      ]),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  // 'grep' kept (in both), 'nonexistent_tool' dropped (not in kind), the
  // kind-only 'read' never enters the face, duplicate 'grep' collapsed.
  assert_eq(composer.specs[0].tools, ["grep"])
}

///|
async test "empty_tool_intersection_errors_with_both_lists" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("kind", Json::string("scout")),
          ("tools", Json::array([Json::string("bash")])),
        ]),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("empty"))
      assert_true(content.contains("bash"))
      assert_true(content.contains("scout"))
      assert_true(content.contains("read"))
    }
    _ => fail("expected empty-intersection error")
  }
}

///|
async test "tools_absent_uses_kind_whitelist" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(
      args_object([("task", Json::string("t")), ("kind", Json::string("scout"))]),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs[0].tools, ["read", "glob", "grep"])
}

///|
async test "instructions_over_8192_chars_rejected" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("instructions", Json::string("x".repeat(8193))),
        ]),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("8192"))
    _ => fail("expected instructions length error")
  }
}

///|
async test "resolve_rejects_model_outside_configured_range" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let base = @kit.SubagentConfig::defaults()
  let config : @kit.SubagentConfig = {
    models: [{ slot: "x", efforts: [], default_effort: None, }],
    default_slot: Some("x"),
    limits: base.limits,
  }
  let tools = test_tools(composer=composer as &ChildComposer, config~)
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(
        args_object([("task", Json::string("t")), ("model", Json::string("y"))]),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("y"))
      assert_true(content.contains("x"))
    }
    _ => fail("expected resolve rejection")
  }
}

///|
async test "composer_failure_maps_to_failed_terminal_state" {
  let composer = FakeComposer::FakeComposer(
    response_text="x",
    fail_with=Some("no features left"),
  )
  let tools = test_tools(composer=composer as &ChildComposer)
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(args_object([("task", Json::string("t"))])),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("failed: no features left"))
      assert_true(content.contains("child_session: subagent-1"))
    }
    _ => fail("expected failed terminal state")
  }
}

///|
async test "background_without_composed_capability_refused_and_does_not_consume_budget" {
  let composer = FakeComposer::FakeComposer(response_text="ok")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_spawn_budget(1),
  )
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(
        args_object([
          ("task", Json::string("bg")),
          ("background", Json::boolean(true)),
        ]),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(
        content.contains(
          "background mode requires the composed task capability",
        ),
      )
    _ => fail("expected capability refusal")
  }
  assert_eq(composer.specs.length(), 0)
  // The refusal happened before the budget gate: the slot is still free.
  assert_eq(tools.ledger.acquired().length(), 0)
  let foreground = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(args_object([("task", Json::string("fg"))])),
  )
  assert_true(foreground is @posoco.ToolOutcome::Success(_))
}

///|
async test "skills_argument_maps_to_child_spec" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  // absent and false → None
  let _ = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(args_object([("task", Json::string("t1"))])),
  )
  let _ = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(
      args_object([
        ("task", Json::string("t2")),
        ("skills", Json::boolean(false)),
      ]),
    ),
  )
  // true → Some([]) (load all discovered)
  let _ = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(
      args_object([
        ("task", Json::string("t3")),
        ("skills", Json::boolean(true)),
      ]),
    ),
  )
  // array → whitelist
  let _ = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(
      args_object([
        ("task", Json::string("t4")),
        ("skills", Json::array([Json::string("alpha"), Json::string("beta")])),
      ]),
    ),
  )
  assert_eq(composer.specs.length(), 4)
  assert_true(composer.specs[0].skills is None)
  assert_true(composer.specs[1].skills is None)
  match composer.specs[2].skills {
    Some(list) => assert_eq(list.length(), 0)
    None => fail("expected Some([]) for skills=true")
  }
  match composer.specs[3].skills {
    Some(list) => assert_eq(list, ["alpha", "beta"])
    None => fail("expected whitelist for skills array")
  }
}

///|
async test "resume_unknown_id_lists_known_children" {
  let composer = FakeComposer::FakeComposer(response_text="first")
  let tools = test_tools(composer=composer as &ChildComposer)
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("resume", Json::string("ghost")),
        ]),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("unknown resume id 'ghost'"))
      assert_true(content.contains("(none spawned yet)"))
    }
    _ => fail("expected unknown-resume error")
  }
  assert_eq(composer.specs.length(), 0)
  // A foreground spawn registers its id (the footer advertises it); the next
  // unknown resume lists exactly that known set.
  let spawned = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(args_object([("task", Json::string("t"))])),
  )
  assert_true(spawned is @posoco.ToolOutcome::Success(_))
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("resume", Json::string("ghost")),
        ]),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("unknown resume id 'ghost'"))
      assert_true(content.contains("subagent-1"))
    }
    _ => fail("expected unknown-resume error listing subagent-1")
  }
}

///|
async test "resume_known_id_passes_session_id_through" {
  let composer = FakeComposer::FakeComposer(response_text="first")
  let tools = test_tools(composer=composer as &ChildComposer)
  let first = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(args_object([("task", Json::string("t1"))])),
  )
  assert_true(first is @posoco.ToolOutcome::Success(_))
  let outcome = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(
      args_object([
        ("task", Json::string("continue")),
        ("resume", Json::string("subagent-1")),
      ]),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs.length(), 2)
  assert_eq(composer.specs[1].session_id, "subagent-1")
  assert_eq(composer.specs[1].resuming, true)
  // The resume re-registered the same id, not a new entry.
  assert_eq(tools.background_children().length(), 1)
}

///|
async test "timeout_ms_enforced_around_child_run" {
  let slow = SlowModel(delay_ms=60000)
  let composer = FakeComposer::FakeComposer(
    response_text="never",
    slow_model=Some(slow as &@posoco.ModelPort),
  )
  let tools = test_tools(composer=composer as &ChildComposer)
  match
    @posoco.ToolProvider::execute(
      tools,
      "agent",
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("timeout_ms", Json::number(100.0)),
        ]),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("timed out"))
      assert_true(content.contains("child_session: subagent-1"))
    }
    other => fail("expected timed-out terminal state, got: \{other}")
  }
}

///|
async test "bridge_observer_forwards_child_events_tagged" {
  let events : Array[@kit.SubagentEvent] = []
  let composer = FakeComposer::FakeComposer(response_text="bridged result")
  let tools = test_tools(composer=composer as &ChildComposer, observers=[
    fn(event) { events.push(event) },
  ])
  let outcome = @posoco.ToolProvider::execute(
    tools,
    "agent",
    agent_call(args_object([("task", Json::string("t"))])),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  let mut completed = 0
  for event in events {
    assert_eq(event.child_session, "subagent-1")
    assert_eq(event.kind, "coder")
    match event.event {
      @posoco.TurnEvent::TurnCompleted => completed = completed + 1
      _ => ()
    }
  }
  assert_true(completed >= 1)
  // The child-side recorder attached by the fake composer also saw events.
  assert_true(composer.child_recorder.events().length() >= 1)
}

///|
async test "unknown_tool_name_raises_unknown_tool" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let raised : Bool = try {
    ignore(
      @posoco.ToolProvider::execute(
        tools,
        "not_agent",
        agent_call(args_object([("task", Json::string("t"))])),
      ),
    )
    false
  } catch {
    @posoco.RuntimeError::UnknownTool(_) => true
    _ => false
  }
  assert_true(raised)
}

///|
async test "missing_task_reports_error" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  match
    @posoco.ToolProvider::execute(tools, "agent", agent_call(args_object([]))) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("task"))
    _ => fail("expected missing-task error")
  }
}

// ---------------------------------------------------------------------------
// Stage B end-to-end: background spawns driven through a real parent Agent
// (Agent::with_runtime harness, mirroring core's runtime seam tests). The
// parent model's first call requests the `agent` tool with background=true;
// the spawn submits through the composed task capability. The child's
// terminal is delivered by core as a user message in the parent session's
// NEXT ordinary turn (no same-turn delivery, no auto wakeup); the
// before_model hook observes it at that delivery point.
// ---------------------------------------------------------------------------

///|
priv struct BgParentModel {
  agent_arguments : Json
  mid_sleep_ms : Int
  mut calls : Int
}

///|
fn BgParentModel::BgParentModel(
  agent_arguments~ : Json,
  mid_sleep_ms~ : Int,
) -> BgParentModel {
  { agent_arguments, mid_sleep_ms, calls: 0, }
}

///|
impl @posoco.ModelPort for BgParentModel with fn chat(
  self : BgParentModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.calls = self.calls + 1
  if self.calls == 1 {
    return @posoco.tk_tool_call_response(
      "agent",
      "call_1",
      self.agent_arguments,
    )
  }
  if self.calls == 2 && self.mid_sleep_ms > 0 {
    @async.sleep(self.mid_sleep_ms)
  }
  @posoco.tk_stop_response("parent step \{self.calls}")
}

///|
impl @posoco.ModelPort for BgParentModel with fn compact(
  _self : BgParentModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "BgParentModel does not implement compact",
  )
}

///|
impl @posoco.ModelPort for BgParentModel with fn provider_config(
  _self : BgParentModel,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
/// Compose the parent Agent for the background e2e tests: SubagentTools goes
/// directly into `exts` (its manifest registers the tool provider, the
/// before_model hook, the parent-session observer, and the lifecycle that
/// captures the task capability) and into the PortRuntime tool map (so the
/// scripted tool call executes it).
fn build_parent_agent(
  tools : SubagentTools,
  model : &@posoco.ModelPort,
  store : @posoco.RecordingSessionStore,
) -> @posoco.Agent raise @error.CompositionError {
  @posoco.Agent::with_runtime(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store]),
      tools as &@posoco.Extension,
    ],
    config=@posoco.tk_config(),
    runtime=@runtime.PortRuntime(
      model~,
      tools=Map::from_array([("agent", tools as &@posoco.ToolProvider)]),
    ),
  )
}

///|
async test "background_child_holds_global_slot_until_task_exit" {
  let probe = ConcurrencyProbeModel::new()
  let composer = FakeComposer::FakeComposer(
    response_text="unused",
    slow_model=Some(probe as &@posoco.ModelPort),
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_global_concurrency(1),
  )
  let model = BgParentModel::BgParentModel(
    agent_arguments=args_object([
      ("task", Json::string("background-one")),
      ("background", Json::boolean(true)),
    ]),
    mid_sleep_ms=0,
  )
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)

  parent.run_scoped(async fn(agent) {
    ignore(agent.run_turn(@posoco.tk_user_msg("start"), "parent_bg_slot"))
    ignore(probe.entered.get())
    assert_eq(probe.peak, 1)
    assert_eq(composer.specs.length(), 1)

    @async.with_task_group(async fn(group) {
      let foreground = group.spawn(async fn() {
        @posoco.ToolProvider::execute(
          tools,
          "agent",
          agent_call(args_object([("task", Json::string("foreground-two"))])),
        )
      })

      // The foreground call has spent its spawn-budget unit but is waiting
      // on the lifetime semaphore: it must not compose/run a second child.
      @async.pause()
      assert_eq(tools.ledger.acquired().length(), 2)
      assert_eq(composer.specs.length(), 1)
      assert_true(probe.entered.try_get() is None)

      // Completing the background child releases its slot only when the
      // Agent-owned task runner exits; then the queued foreground call starts.
      probe.release.put(())
      ignore(probe.entered.get())
      assert_eq(probe.peak, 1)
      assert_eq(composer.specs.length(), 2)

      probe.release.put(())
      assert_true(foreground.wait() is @posoco.ToolOutcome::Success(_))
    })
  })
  assert_eq(tools.ledger.acquired().length(), 2)
}

///|
async test "background_cancellation_releases_global_slot" {
  let probe = ConcurrencyProbeModel::new()
  let composer = FakeComposer::FakeComposer(
    response_text="unused",
    slow_model=Some(probe as &@posoco.ModelPort),
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_global_concurrency(1),
  )
  let model = BgParentModel::BgParentModel(
    agent_arguments=args_object([
      ("task", Json::string("cancel-me")),
      ("background", Json::boolean(true)),
    ]),
    mid_sleep_ms=0,
  )
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)

  parent.run_scoped(async fn(agent) {
    ignore(agent.run_turn(@posoco.tk_user_msg("start"), "parent_bg_cancel"))
    ignore(probe.entered.get())
    assert_false(tools.global_slots.try_acquire())
    // Returning closes the parent task scope. Core cancels the live
    // background task; its runner's errdefer must release the semaphore.
  })

  assert_true(tools.global_slots.try_acquire())
  tools.global_slots.release()
}

///|
async test "background_completed_delivers_on_next_turn_and_records_terminal" {
  let events : Array[@kit.SubagentEvent] = []
  let composer = FakeComposer::FakeComposer(
    response_text="child finished early",
  )
  let tools = test_tools(composer=composer as &ChildComposer, observers=[
    fn(event) { events.push(event) },
  ])
  let model = BgParentModel::BgParentModel(
    agent_arguments=args_object([
      ("task", Json::string("dig")),
      ("background", Json::boolean(true)),
    ]),
    mid_sleep_ms=0,
  )
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@posoco.tk_user_msg("go dig"), "parent_bg")
    // turn1 = tool-request call + post-tool stop; no same-turn delivery.
    assert_eq(model.calls, 2)
    @async.sleep(500)
    // The child's outcome is already enqueued but not yet observed: the
    // terminal is only recorded at the delivery point (turn 2's before_model).
    assert_eq(tools.background_children(), [("subagent-1", "running")])
    let _ = agent.run_turn(@posoco.tk_user_msg("again"), "parent_bg")
  })
  // turn2 delivered the outcome: one stop call.
  assert_eq(model.calls, 3)
  assert_eq(composer.specs.length(), 1)
  assert_eq(composer.specs[0].session_id, "subagent-1")
  match tools.registry.get("subagent-1") {
    Some(record) =>
      match record.state {
        Done("completed", summary) =>
          assert_true(summary.contains("child finished early"))
        _ => fail("expected completed registry state for subagent-1")
      }
    None => fail("expected a registry record for subagent-1")
  }
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
  // The delivery is persisted as a user message in the parent session.
  assert_true(
    store_contains_user_text(store, "parent_bg", "[posoco-task-outcome id="),
  )
  // The subscription channel saw spawned first, terminal second.
  let mut spawned_at = -1
  let mut terminal_at = -1
  for i, event in events {
    assert_eq(event.child_session, "subagent-1")
    assert_eq(event.kind, "coder")
    match event.event {
      @posoco.TurnEvent::Custom(label~, data~, ..) => {
        if label == "background_spawned" {
          spawned_at = i
          assert_true(data is Json::Object(_))
        }
        if label == "background_terminal" {
          terminal_at = i
          match data {
            Json::Object(fields) =>
              match fields.get("state") {
                Some(Json::String("completed")) => ()
                _ => fail("expected terminal event state completed")
              }
            _ => fail("expected terminal event data object")
          }
        }
      }
      _ => ()
    }
  }
  assert_true(spawned_at >= 0)
  assert_true(terminal_at > spawned_at)
}

///|
async test "background_timeout_maps_to_timed_out_via_delivery" {
  let slow = SlowModel(delay_ms=60000)
  let composer = FakeComposer::FakeComposer(
    response_text="never",
    slow_model=Some(slow as &@posoco.ModelPort),
  )
  let tools = test_tools(composer=composer as &ChildComposer)
  let model = BgParentModel::BgParentModel(
    agent_arguments=args_object([
      ("task", Json::string("slow job")),
      ("background", Json::boolean(true)),
      ("timeout_ms", Json::number(100.0)),
    ]),
    mid_sleep_ms=0,
  )
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@posoco.tk_user_msg("start slow"), "parent_bg")
    @async.sleep(500)
    let _ = agent.run_turn(@posoco.tk_user_msg("again"), "parent_bg")
  })
  // Core timed the task out at 100ms and delivered the terminal on turn 2.
  match tools.registry.get("subagent-1") {
    Some(record) =>
      match record.state {
        Done("timed_out", summary) => assert_true(summary.contains("timed out"))
        _ => fail("expected timed_out registry state for subagent-1")
      }
    None => fail("expected a registry record for subagent-1")
  }
  assert_eq(tools.background_children(), [("subagent-1", "timed_out")])
  assert_true(
    store_contains_user_text(store, "parent_bg", "[posoco-task-outcome id="),
  )
}

///|
async test "subscribe_receives_spawned_and_terminal_events" {
  let composer = FakeComposer::FakeComposer(response_text="done deal")
  let tools = test_tools(composer=composer as &ChildComposer)
  let events : Array[@kit.SubagentEvent] = []
  tools.subscribe(fn(event) { events.push(event) })
  let model = BgParentModel::BgParentModel(
    agent_arguments=args_object([
      ("task", Json::string("t")),
      ("background", Json::boolean(true)),
    ]),
    mid_sleep_ms=0,
  )
  let parent = build_parent_agent(
    tools,
    model as &@posoco.ModelPort,
    @posoco.RecordingSessionStore::RecordingSessionStore(),
  )
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@posoco.tk_user_msg("go dig"), "parent_bg")
    @async.sleep(400)
    let _ = agent.run_turn(@posoco.tk_user_msg("again"), "parent_bg")
  })
  let mut spawned = 0
  let mut terminal = 0
  for event in events {
    assert_eq(event.child_session, "subagent-1")
    assert_eq(event.kind, "coder")
    match event.event {
      @posoco.TurnEvent::Custom(source~, label~, data~) => {
        assert_eq(source, "posoco_ext_subagent")
        if label == "background_spawned" {
          spawned = spawned + 1
        }
        if label == "background_terminal" {
          terminal = terminal + 1
          match data {
            Json::Object(fields) =>
              match fields.get("state") {
                Some(Json::String("completed")) => ()
                _ => fail("expected terminal event state completed")
              }
            _ => fail("expected terminal event data object")
          }
        }
      }
      _ => ()
    }
  }
  assert_eq(spawned, 1)
  assert_eq(terminal, 1)
}
