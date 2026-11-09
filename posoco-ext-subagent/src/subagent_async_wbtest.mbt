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
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("write the tests")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
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
  entered : @async.Queue[Int32]
  release : @async.Queue[Unit]
  mut active : Int32
  mut peak : Int32
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
  @tk.tk_stop_response("released")
}

///|
impl @posoco.ModelPort for ConcurrencyProbeModel with fn compact(
  _self : ConcurrencyProbeModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
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
            test_ctx(
              agent_call(
                args_object([
                  ("task", Json::string(task)),
                  ("background", Json::boolean(false)),
                ]),
              ),
            ),
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
  mut failures : Int32
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
      name: @posoco.ToolName::unchecked("subagent"),
      arguments: args_object([
        ("task", Json::string("explode")),
        ("background", Json::boolean(false)),
      ]),
    },
    {
      call_id: @posoco.CallId::unchecked("sibling-ok"),
      name: @posoco.ToolName::unchecked("subagent"),
      arguments: args_object([
        ("task", Json::string("survive")),
        ("background", Json::boolean(false)),
      ]),
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
  @posoco.Observer::on_event(
    tools,
    Some(scope1),
    @posoco.TurnEvent::TurnStarted,
  )
  for task in ["one", "two"] {
    let outcome = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string(task)),
            ("background", Json::boolean(false)),
          ]),
        ),
      ),
    )
    assert_true(outcome is @posoco.ToolOutcome::Success(_))
  }
  assert_eq(tools.ledger.remaining(), 0)

  // Ordinary events in the same run do not replenish the budget.
  @posoco.Observer::on_event(
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
  @posoco.Observer::on_event(
    tools,
    Some(scope2),
    @posoco.TurnEvent::TurnStarted,
  )
  assert_eq(tools.ledger.remaining(), 2)
  let next = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("three")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
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
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("first")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
  )
  assert_true(first is @posoco.ToolOutcome::Success(_))
  match
    @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("second")),
            ("background", Json::boolean(false)),
          ]),
        ),
      ),
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
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(sibling_failure_wave()),
    @tk.ScriptedModelStep::Respond(
      @tk.tk_stop_response("parent recovered after sibling failure"),
    ),
  ])
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let result = parent.run_scoped(async fn(agent) {
    agent.run_turn(
      @tk.tk_user_msg("run two independent children"),
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
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("t")),
            ("background", Json::boolean(false)),
            ("kind", Json::string("wizard")),
          ]),
        ),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("unknown kind 'wizard'"))
      assert_true(content.contains("coder"))
      assert_true(content.contains("explore"))
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
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
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
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  // 'grep' kept (in both), 'nonexistent_tool' dropped (not in kind), the
  // kind-only 'read' never enters the face, duplicate 'grep' collapsed.
  assert_eq(composer.specs[0].tools, Some(["grep"]))
}

///|
async test "empty_tool_intersection_errors_with_both_lists" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  match
    @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("t")),
            ("background", Json::boolean(false)),
            ("kind", Json::string("explore")),
            ("tools", Json::array([Json::string("bash")])),
          ]),
        ),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("empty"))
      assert_true(content.contains("bash"))
      assert_true(content.contains("explore"))
      assert_true(content.contains("read"))
    }
    _ => fail("expected empty-intersection error")
  }
}

///|
async test "kind_binding_beats_config_default" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_default(model="mtplx/local", effort=Some("low")),
    catalog=catalog_with_bound_kind(),
  )
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("porter")),
        ]),
      ),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs[0].slot, "kimi/k2")
  // The kind's bound effort wins; the config default never mixes in.
  assert_eq(composer.specs[0].effort, Some("high"))
}

///|
async test "explicit_args_override_kind_binding" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_default(model="mtplx/local", effort=Some("low")),
    catalog=catalog_with_bound_kind(),
  )
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("porter")),
          ("model", Json::string("zai/glm")),
          ("effort", Json::string("low")),
        ]),
      ),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs[0].slot, "zai/glm")
  assert_eq(composer.specs[0].effort, Some("low"))
}

///|
async test "default_model_applies_to_unbound_kinds" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_default(model="mtplx/local", effort=Some("low")),
    catalog=catalog_with_bound_kind(),
  )
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("coder")),
        ]),
      ),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs[0].slot, "mtplx/local")
  assert_eq(composer.specs[0].effort, Some("low"))
}

///|
async test "unbound_kind_inherits_parent_when_no_default" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
  )
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("coder")),
        ]),
      ),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs[0].slot, "parent/slot")
  assert_true(composer.specs[0].effort is None)
}

///|
async test "tools_absent_uses_kind_whitelist" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("explore")),
        ]),
      ),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs[0].tools, Some(["read", "glob", "grep"]))
}

///|
async test "unbound_kind_face_inherits_default_as_none" {
  // Face None (host default, includes ask_question) is interactive, so the
  // spawn rides the composed task capability: drive it through a real
  // parent Agent instead of a bare provider call.
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
  )
  let model = BgParentModel::BgParentModel(
    agent_arguments=args_object([
      ("task", Json::string("t")),
      ("background", Json::boolean(false)),
      ("kind", Json::string("loose")),
    ]),
    mid_sleep_ms=0,
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go"), "parent_face")
    ()
  })
  assert_true(composer.specs[0].tools is None)
  // Explicit args.tools on an inheriting kind are kept as-is (and a face
  // without ask_question stays on the synchronous path, so a bare provider
  // call still works).
  let narrowed = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("loose")),
          ("tools", Json::array([Json::string("grep")])),
        ]),
      ),
    ),
  )
  assert_true(narrowed is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs[1].tools, Some(["grep"]))
}

///|
async test "instructions_over_8192_chars_rejected" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  match
    @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("t")),
            ("background", Json::boolean(false)),
            ("instructions", Json::string("x".repeat(8193))),
          ]),
        ),
      ),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("8192"))
    _ => fail("expected instructions length error")
  }
}

///|
async test "explicit_literal_model_falls_back_to_parent_effort" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    parent_selection=Some(fn() { ("parent/slot", Some("max")) }),
  )
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("coder")),
          ("model", Json::string("zai/glm")),
        ]),
      ),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs[0].slot, "zai/glm")
  assert_eq(composer.specs[0].effort, Some("max"))
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
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("t")),
            ("background", Json::boolean(false)),
          ]),
        ),
      ),
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
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("bg")),
            ("background", Json::boolean(true)),
          ]),
        ),
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
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("fg")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
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
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t1")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
  )
  let _ = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t2")),
          ("background", Json::boolean(false)),
          ("skills", Json::boolean(false)),
        ]),
      ),
    ),
  )
  // true → Some([]) (load all discovered)
  let _ = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t3")),
          ("background", Json::boolean(false)),
          ("skills", Json::boolean(true)),
        ]),
      ),
    ),
  )
  // array → whitelist
  let _ = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t4")),
          ("background", Json::boolean(false)),
          ("skills", Json::array([Json::string("alpha"), Json::string("beta")])),
        ]),
      ),
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
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("t")),
            ("background", Json::boolean(false)),
            ("resume", Json::string("ghost")),
          ]),
        ),
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
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
  )
  assert_true(spawned is @posoco.ToolOutcome::Success(_))
  match
    @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("t")),
            ("background", Json::boolean(false)),
            ("resume", Json::string("ghost")),
          ]),
        ),
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
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t1")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
  )
  assert_true(first is @posoco.ToolOutcome::Success(_))
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("continue")),
          ("background", Json::boolean(false)),
          ("resume", Json::string("subagent-1")),
        ]),
      ),
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
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("t")),
            ("background", Json::boolean(false)),
            ("timeout_ms", Json::number(100.0)),
          ]),
        ),
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
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
  )
  assert_true(outcome is @posoco.ToolOutcome::Success(_))
  let mut completed = 0
  for event in events {
    assert_eq(event.child_session, "subagent-1")
    assert_eq(event.kind, "coder")
    // The bridge tags events with the spawning parent tool-call id.
    assert_eq(event.parent_call, "agent-test")
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
  // The name now rides the call itself, so the unknown name goes in the call.
  let call = agent_call(
    args_object([
      ("task", Json::string("t")),
      ("background", Json::boolean(false)),
    ]),
  )
  let stranger : @posoco.ToolCall = {
    call_id: call.call_id,
    name: @posoco.ToolName::unchecked("not_agent"),
    arguments: call.arguments,
  }
  let raised : Bool = try {
    ignore(@posoco.ToolProvider::execute(tools, test_ctx(stranger)))
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
    @posoco.ToolProvider::execute(tools, test_ctx(agent_call(args_object([])))) {
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
  mid_sleep_ms : Int32
  mut calls : Int32
}

///|
fn BgParentModel::BgParentModel(
  agent_arguments~ : Json,
  mid_sleep_ms~ : Int32,
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
    return @tk.tk_tool_call_response("subagent", "call_1", self.agent_arguments)
  }
  if self.calls == 2 && self.mid_sleep_ms > 0 {
    @async.sleep(self.mid_sleep_ms)
  }
  @tk.tk_stop_response("parent step \{self.calls}")
}

///|
impl @posoco.ModelPort for BgParentModel with fn compact(
  _self : BgParentModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
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
  store : @tk.RecordingSessionPort,
) -> @posoco.Agent raise @error.CompositionError {
  @posoco.Agent::with_runtime(
    exts=[
      @tk.tk_ext(id="model", model=Some(model)),
      @tk.tk_ext(id="io", sessions=[store]),
      tools as &@posoco.Extension,
    ],
    config=@tk.tk_config(),
    events=@posoco.EventSystem(),
    runtime=@runtime.PortRuntime(model~),
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
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)

  parent.run_scoped(async fn(agent) {
    ignore(agent.run_turn(@tk.tk_user_msg("start"), "parent_bg_slot"))
    ignore(probe.entered.get())
    assert_eq(probe.peak, 1)
    assert_eq(composer.specs.length(), 1)

    @async.with_task_group(async fn(group) {
      let foreground = group.spawn(async fn() {
        @posoco.ToolProvider::execute(
          tools,
          test_ctx(
            agent_call(
              args_object([
                ("task", Json::string("foreground-two")),
                ("background", Json::boolean(false)),
              ]),
            ),
          ),
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
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)

  parent.run_scoped(async fn(agent) {
    ignore(agent.run_turn(@tk.tk_user_msg("start"), "parent_bg_cancel"))
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
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go dig"), "parent_bg")
    // turn1 = tool-request call + post-tool stop; no same-turn delivery.
    assert_eq(model.calls, 2)
    @async.sleep(500)
    // The child's outcome is already enqueued but not yet observed: the
    // terminal is only recorded at the delivery point (turn 2's before_model).
    assert_eq(tools.background_children(), [("subagent-1", "running")])
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_bg")
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
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("start slow"), "parent_bg")
    @async.sleep(500)
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_bg")
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
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go dig"), "parent_bg")
    @async.sleep(400)
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_bg")
  })
  let mut spawned = 0
  let mut terminal = 0
  for event in events {
    assert_eq(event.child_session, "subagent-1")
    assert_eq(event.kind, "coder")
    match event.event {
      @posoco.TurnEvent::Custom(source~, label~, data~) => {
        // Posoco 0.21 projects core operation lifecycle Custom events through
        // child observers too. The bridge deliberately forwards the complete
        // child event stream, so only extension-owned labels constrain the
        // extension source here.
        if label == "background_spawned" {
          assert_eq(source, "posoco_ext_subagent")
          spawned = spawned + 1
        }
        if label == "background_terminal" {
          assert_eq(source, "posoco_ext_subagent")
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

///|
/// Child model that always fails the turn: drives the runner's error path.
priv struct FailingModel {
  reason : String
}

///|
fn FailingModel::FailingModel(reason~ : String) -> FailingModel {
  { reason, }
}

///|
impl @posoco.ModelPort for FailingModel with fn chat(
  self : FailingModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(self.reason)
}

///|
impl @posoco.ModelPort for FailingModel with fn compact(
  _self : FailingModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "FailingModel does not implement compact",
  )
}

///|
impl @posoco.ModelPort for FailingModel with fn provider_config(
  _self : FailingModel,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
/// The exit declaration fires at true task exit, before any delivery: after
/// the child has died but before turn 2, the subscription already saw
/// `background_exited` while the registry still says "running" and no
/// authoritative `background_terminal` has fired.
async test "background_exit_declares_completed_at_task_exit" {
  let events : Array[@kit.SubagentEvent] = []
  let composer = FakeComposer::FakeComposer(response_text="child done")
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
  let parent = build_parent_agent(
    tools,
    model as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go dig"), "parent_bg")
    @async.sleep(300)
    // Child has exited; the declaration is already out, the authoritative
    // terminal is not (delivery happens at turn 2).
    let mut exited_at = -1
    let mut terminal_at = -1
    for i, event in events {
      match event.event {
        @posoco.TurnEvent::Custom(label~, data~, ..) => {
          if label == "background_exited" {
            exited_at = i
            match data {
              Json::Object(fields) =>
                match fields.get("state") {
                  Some(Json::String("completed")) => ()
                  _ => fail("expected exited state completed")
                }
              _ => fail("expected exited event data object")
            }
          }
          if label == "background_terminal" {
            terminal_at = i
          }
        }
        _ => ()
      }
    }
    assert_true(exited_at >= 0)
    assert_true(terminal_at < 0)
    assert_eq(tools.background_children(), [("subagent-1", "running")])
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_bg")
  })
  let mut exited = 0
  let mut terminal = 0
  let mut spawned = 0
  for event in events {
    match event.event {
      @posoco.TurnEvent::Custom(label~, ..) => {
        if label == "background_spawned" {
          spawned += 1
        }
        if label == "background_exited" {
          exited += 1
        }
        if label == "background_terminal" {
          terminal += 1
        }
      }
      _ => ()
    }
  }
  assert_eq(spawned, 1)
  assert_eq(exited, 1)
  assert_eq(terminal, 1)
}

///|
/// A child whose model explodes declares `failed` at exit; the delivery
/// point later records the authoritative failed terminal.
async test "background_exit_declares_failed_on_child_error" {
  let events : Array[@kit.SubagentEvent] = []
  let composer = FakeComposer::FakeComposer(
    response_text="never",
    slow_model=Some(
      FailingModel::FailingModel(reason="child model exploded")
      as &@posoco.ModelPort,
    ),
  )
  let tools = test_tools(composer=composer as &ChildComposer, observers=[
    fn(event) { events.push(event) },
  ])
  let model = BgParentModel::BgParentModel(
    agent_arguments=args_object([
      ("task", Json::string("doomed")),
      ("background", Json::boolean(true)),
    ]),
    mid_sleep_ms=0,
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("start"), "parent_bg")
    @async.sleep(300)
    let mut failed_exit = false
    for event in events {
      match event.event {
        @posoco.TurnEvent::Custom(label~, data~, ..) =>
          if label == "background_exited" {
            match data {
              Json::Object(fields) =>
                match fields.get("state") {
                  Some(Json::String("failed")) => failed_exit = true
                  _ => fail("expected exited state failed")
                }
              _ => fail("expected exited event data object")
            }
          }
        _ => ()
      }
    }
    assert_true(failed_exit)
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_bg")
  })
  match tools.registry.get("subagent-1") {
    Some(record) =>
      match record.state {
        Done("failed", summary) =>
          assert_true(summary.contains("child model exploded"))
        _ => fail("expected failed registry state for subagent-1")
      }
    None => fail("expected a registry record for subagent-1")
  }
}

///|
/// Core's timeout cancels the runner, so the exit declaration can only say
/// "cancelled" (best-effort); the delivery point records the authoritative
/// "timed_out". This gap is documented, not a bug.
async test "background_timeout_exits_cancelled_then_records_timed_out" {
  let events : Array[@kit.SubagentEvent] = []
  let slow = SlowModel(delay_ms=60000)
  let composer = FakeComposer::FakeComposer(
    response_text="never",
    slow_model=Some(slow as &@posoco.ModelPort),
  )
  let tools = test_tools(composer=composer as &ChildComposer, observers=[
    fn(event) { events.push(event) },
  ])
  let model = BgParentModel::BgParentModel(
    agent_arguments=args_object([
      ("task", Json::string("slow job")),
      ("background", Json::boolean(true)),
      ("timeout_ms", Json::number(100.0)),
    ]),
    mid_sleep_ms=0,
  )
  let parent = build_parent_agent(
    tools,
    model as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("start slow"), "parent_bg")
    @async.sleep(500)
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_bg")
  })
  let mut exited_state = ""
  let mut terminal_state = ""
  for event in events {
    match event.event {
      @posoco.TurnEvent::Custom(label~, data~, ..) => {
        if label == "background_exited" {
          match data {
            Json::Object(fields) =>
              match fields.get("state") {
                Some(Json::String(state)) => exited_state = state
                _ => fail("expected exited event state")
              }
            _ => fail("expected exited event data object")
          }
        }
        if label == "background_terminal" {
          match data {
            Json::Object(fields) =>
              match fields.get("state") {
                Some(Json::String(state)) => terminal_state = state
                _ => fail("expected terminal event state")
              }
            _ => fail("expected terminal event data object")
          }
        }
      }
      _ => ()
    }
  }
  assert_eq(exited_state, "cancelled")
  assert_eq(terminal_state, "timed_out")
}

// ---------------------------------------------------------------------------
// Stage C end-to-end: interactive children that ask their parent a question
// through the question broker. The fake composer injects an `ask_parent`
// tool that parks on the shared broker's channel — exactly the shape a real
// cetas-js child's `ask_question_child` face has — and a scene parent model
// replays the parent side (spawn → waiting_reply receipt → answer → ack).
// ---------------------------------------------------------------------------

///|
/// Child-side ask tool bound to one child session: one ask per run, the
/// answer recorded for assertions.
priv struct AskParentTool {
  child_session : String
  channel : ParentQuestionChannel
  req : @posoco.UiRequest
  /// Parking delay before the ask registers (cancellation-race tests).
  ask_delay_ms : Int32
  /// Signal once the child's tool tree has begun executing this tool.
  ask_started : @async.Queue[Unit]?
  answers : Array[String]
}

///|
impl @posoco.ToolProvider for AskParentTool with fn list_tools(
  _self : AskParentTool,
) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef(
      name=@posoco.ToolName::unchecked("ask_parent"),
      description="test tool: ask the parent agent one question",
      input_schema=Json::object(Map::from_array([])),
      owner=@posoco.OwnerId::unchecked("wbtest"),
      policy=@posoco.ExecutionPolicy::Exclusive,
      provenance=None,
    ),
  ]
}

///|
impl @posoco.ToolProvider for AskParentTool with fn execute(
  self : AskParentTool,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if ctx.name.to_string() != "ask_parent" {
    raise @posoco.RuntimeError::UnknownTool("ask_parent: unknown tool")
  }
  match self.ask_started {
    Some(queue) => ignore(queue.try_put(()) catch { _ => false })
    None => ()
  }
  if self.ask_delay_ms > 0 {
    @async.sleep(self.ask_delay_ms)
  }
  let response = self.channel.ask(
    child_session=self.child_session,
    origin_call=ctx.call_id.to_string(),
    req=self.req,
  ) catch {
    QuestionError::TimedOut => {
      self.answers.push("\{self.child_session}=timeout")
      return @posoco.ToolOutcome::ToolReportedError(
        content="answer timed out",
        structured=None,
      )
    }
    QuestionError::Cancelled => {
      self.answers.push("\{self.child_session}=cancelled")
      return @posoco.ToolOutcome::ToolReportedError(
        content="cancelled",
        structured=None,
      )
    }
    QuestionError::Unsupported(detail) => {
      self.answers.push("\{self.child_session}=unsupported")
      return @posoco.ToolOutcome::ToolReportedError(
        content="unsupported: \{detail}",
        structured=None,
      )
    }
    QuestionError::Io(detail) => {
      self.answers.push("\{self.child_session}=io")
      return @posoco.ToolOutcome::ToolReportedError(
        content="io: \{detail}",
        structured=None,
      )
    }
  }
  let text = match response {
    @posoco.UiResponse::Text(text) => text
    @posoco.UiResponse::Yes => "yes"
    @posoco.UiResponse::No => "no"
    @posoco.UiResponse::Selected(index) => "sel:\{index}"
    @posoco.UiResponse::Cancelled => "cancelled-response"
  }
  self.answers.push("\{self.child_session}=\{text}")
  @posoco.ToolOutcome::Success(content=text, structured=None)
}

///|
/// Composer whose children ask one question then finish — but only when
/// their face is interactive; a face without ask_question gets a plain
/// completing child, mirroring the host-glue binding rule.
priv struct AskingComposer {
  channel : ParentQuestionChannel
  req : @posoco.UiRequest
  finish_text : String
  ask_delay_ms : Int32
  ask_started : @async.Queue[Unit]?
  /// How many times the child asks before finishing.
  asks : Int32
  /// Per-child override of `asks`, indexed by composition order (spawn and
  /// resume alike): a test can make one run silent and its resume ask.
  asks_per_run : Array[Int32]
  answers : Array[String]
  specs : Array[ChildSpec]
}

///|
fn AskingComposer::AskingComposer(
  channel~ : ParentQuestionChannel,
  req~ : @posoco.UiRequest,
  finish_text~ : String,
  ask_delay_ms~ : Int32 = 0,
  ask_started~ : @async.Queue[Unit]? = None,
  asks~ : Int32 = 1,
  asks_per_run~ : Array[Int32] = [],
) -> AskingComposer {
  {
    channel,
    req,
    finish_text,
    ask_delay_ms,
    ask_started,
    asks,
    asks_per_run,
    answers: [],
    specs: [],
  }
}

///|
impl ChildComposer for AskingComposer with fn compose(
  self : AskingComposer,
  spec : ChildSpec,
) -> @posoco.Agent raise ComposerError {
  self.specs.push(spec)
  let asks = match spec.tools {
    Some(names) => list_contains(names, "ask_question")
    None => true
  }
  let observers : Array[&@posoco.Observer] = []
  for observer in spec.observers {
    observers.push(observer)
  }
  let exts : Array[&@posoco.Extension] = []
  if asks {
    let ask_count = match self.asks_per_run.get(self.specs.length() - 1) {
      Some(count) => count
      None => self.asks
    }
    let steps : Array[@tk.ScriptedModelStep] = []
    for i in 0..<ask_count {
      steps.push(
        @tk.ScriptedModelStep::Respond(
          @tk.tk_tool_call_response(
            "ask_parent",
            "child-ask-\{i + 1}",
            Json::object(Map::from_array([])),
          ),
        ),
      )
    }
    steps.push(
      @tk.ScriptedModelStep::Respond(@tk.tk_stop_response(self.finish_text)),
    )
    let model = @tk.ScriptedModel(steps)
    exts.push(@tk.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)))
    exts.push(
      @tk.tk_ext(id="ask", tools=[
        {
          child_session: spec.session_id,
          channel: self.channel,
          req: self.req,
          ask_delay_ms: self.ask_delay_ms,
          ask_started: self.ask_started,
          answers: self.answers,
        }
        as &@posoco.ToolProvider,
      ]),
    )
  } else {
    let model = @tk.ScriptedModel([
      @tk.ScriptedModelStep::Respond(@tk.tk_stop_response(self.finish_text)),
    ])
    exts.push(@tk.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)))
  }
  exts.push(
    @tk.tk_ext(
      id="io",
      sessions=[
        @tk.RecordingSessionPort::RecordingSessionPort() as &@posoco.SessionPort,
      ],
      observers~,
    ),
  )
  @posoco.Agent(exts~, config=@tk.tk_config(), events=@posoco.EventSystem()) catch {
    error => raise ComposerError::Failed("child compose failed: \{error}")
  }
}

///|
/// Full-text projection for scene assertions: user/system/assistant text
/// blocks plus tool outcomes (the receipt under test rides a ToolMessage).
fn scene_input_text(messages : ArrayView[@posoco.Message]) -> String {
  let parts : Array[String] = []
  for message in messages {
    match message {
      @posoco.Message::UserMessage(content~) =>
        for block in content {
          match block {
            @posoco.Content::Text(text) => parts.push(text)
            @posoco.Content::Image(..) => ()
          }
        }
      @posoco.Message::ToolMessage(outcome~, ..) =>
        match outcome {
          @posoco.ToolOutcome::Success(content~, ..) => parts.push(content)
          @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
            parts.push(content)
          _ => ()
        }
      _ => ()
    }
  }
  parts.join("\n")
}

///|
/// Parent model that replays scripted responses in order and records what
/// each chat call saw: the model input text and the live child-registry
/// projection.
priv struct SceneParentModel {
  steps : Array[@posoco.ModelCallResult]
  children : () -> Array[(String, String)]
  mut calls : Int32
  inputs : Array[String]
  states : Array[Array[(String, String)]]
}

///|
fn SceneParentModel::SceneParentModel(
  steps~ : Array[@posoco.ModelCallResult],
  children~ : () -> Array[(String, String)],
) -> SceneParentModel {
  { steps, children, calls: 0, inputs: [], states: [], }
}

///|
impl @posoco.ModelPort for SceneParentModel with fn chat(
  self : SceneParentModel,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.inputs.push(scene_input_text(messages))
  self.states.push((self.children)())
  self.calls = self.calls + 1
  if self.calls <= self.steps.length() {
    self.steps[self.calls - 1]
  } else {
    @tk.tk_stop_response("parent step \{self.calls}")
  }
}

///|
impl @posoco.ModelPort for SceneParentModel with fn compact(
  _self : SceneParentModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "SceneParentModel does not implement compact",
  )
}

///|
impl @posoco.ModelPort for SceneParentModel with fn provider_config(
  _self : SceneParentModel,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
fn answer_call(pairs : Array[(String, Json)]) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("answer-test"),
    name: @posoco.ToolName::unchecked("answer_question"),
    arguments: args_object(pairs),
  }
}

///|
fn two_agent_wave(
  first_task : String,
  second_task : String,
) -> @posoco.ModelCallResult {
  let calls : Array[@posoco.ToolCall] = [
    {
      call_id: @posoco.CallId::unchecked("wave-a"),
      name: @posoco.ToolName::unchecked("subagent"),
      arguments: args_object([
        ("task", Json::string(first_task)),
        ("background", Json::boolean(false)),
        ("kind", Json::string("loose")),
      ]),
    },
    {
      call_id: @posoco.CallId::unchecked("wave-b"),
      name: @posoco.ToolName::unchecked("subagent"),
      arguments: args_object([
        ("task", Json::string(second_task)),
        ("background", Json::boolean(false)),
        ("kind", Json::string("loose")),
      ]),
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
async test "interactive_child_roundtrip_input_question" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=5000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="which file?", default=None),
    finish_text="task complete",
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let model = SceneParentModel::SceneParentModel(
    steps=[
      @tk.tk_tool_call_response(
        "subagent",
        "spawn-1",
        args_object([
          ("task", Json::string("find the file")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("loose")),
        ]),
      ),
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-1",
        args_object([
          ("question_id", Json::string("question-1")),
          ("text", Json::string("src/lib/agent.mbt")),
        ]),
      ),
      @tk.tk_stop_response("parent done"),
    ],
    children=fn() { tools.background_children() },
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go"), "parent_scene")
    @async.sleep(50)
    let _ = agent.run_turn(@tk.tk_user_msg("next"), "parent_scene")
    ()
  })
  // The receipt reached the parent model before any answer existed.
  assert_true(model.inputs.length() >= 2)
  assert_true(model.inputs[1].contains("waiting_reply"))
  assert_true(model.inputs[1].contains("which file?"))
  assert_true(model.inputs[1].contains("answer_question"))
  assert_eq(model.states[1], [("subagent-1", "waiting_reply")])
  // The answer receipt carries the question→answer pair for the transcript.
  assert_true(model.inputs.length() >= 3)
  assert_true(model.inputs[2].contains("question: which file?"))
  assert_true(model.inputs[2].contains("answer: src/lib/agent.mbt"))
  // The answer reached the child in its original session.
  assert_eq(composer.answers, ["subagent-1=src/lib/agent.mbt"])
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
  assert_true(model.inputs[model.inputs.length() - 1].contains("task complete"))
}

///|
async test "interactive_child_select_validation_and_double_answer" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=5000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Select(
      prompt="pick one",
      options=["alpha", "beta"],
      default=None,
    ),
    finish_text="picked",
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let model = SceneParentModel::SceneParentModel(
    steps=[
      @tk.tk_tool_call_response(
        "subagent",
        "spawn-1",
        args_object([
          ("task", Json::string("pick")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("loose")),
        ]),
      ),
      // Out-of-range select answer: recoverable error, child keeps waiting.
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-oob",
        args_object([
          ("question_id", Json::string("question-1")),
          ("index", Json::number(5.0)),
        ]),
      ),
      // Type mismatch: text field against a select question.
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-mismatch",
        args_object([
          ("question_id", Json::string("question-1")),
          ("text", Json::string("neither")),
        ]),
      ),
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-ok",
        args_object([
          ("question_id", Json::string("question-1")),
          ("index", Json::number(1.0)),
        ]),
      ),
      // Duplicate answer: explicitly rejected.
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-dupe",
        args_object([
          ("question_id", Json::string("question-1")),
          ("index", Json::number(0.0)),
        ]),
      ),
      @tk.tk_stop_response("parent done"),
    ],
    children=fn() { tools.background_children() },
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go"), "parent_select")
    @async.sleep(50)
    let _ = agent.run_turn(@tk.tk_user_msg("next"), "parent_select")
    ()
  })
  assert_true(model.inputs[2].contains("out of range"))
  assert_true(model.inputs[3].contains("is type select"))
  // The accepted select answer echoes the question and the resolved option.
  assert_true(model.inputs[4].contains("question: pick one"))
  assert_true(model.inputs[4].contains("answer: beta (index 1)"))
  assert_eq(composer.answers, ["subagent-1=sel:1"])
  assert_true(model.inputs[5].contains("already answered"))
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
}

///|
/// The deadlock regression: two interactive children in ONE parallel wave
/// both ask; both receipts must return before any answer exists, and the
/// answers must not cross.
async test "two_interactive_children_same_wave_no_deadlock" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=5000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="need a fact", default=None),
    finish_text="done with the fact",
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let model = SceneParentModel::SceneParentModel(
    steps=[
      two_agent_wave("first task", "second task"),
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-1",
        args_object([
          ("question_id", Json::string("question-1")),
          ("text", Json::string("fact-one")),
        ]),
      ),
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-2",
        args_object([
          ("question_id", Json::string("question-2")),
          ("text", Json::string("fact-two")),
        ]),
      ),
      @tk.tk_stop_response("parent done"),
    ],
    children=fn() { tools.background_children() },
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go"), "parent_wave")
    @async.sleep(50)
    let _ = agent.run_turn(@tk.tk_user_msg("next"), "parent_wave")
    ()
  })
  // Both receipts came back in the same wave, each carrying its own id.
  assert_true(model.inputs[1].contains("question-1"))
  assert_true(model.inputs[1].contains("question-2"))
  assert_eq(model.states[1], [
    ("subagent-1", "waiting_reply"),
    ("subagent-2", "waiting_reply"),
  ])
  // Answers routed to the asking child, not crossed.
  let sorted_answers = composer.answers.copy()
  sorted_answers.sort()
  assert_eq(sorted_answers, ["subagent-1=fact-one", "subagent-2=fact-two"])
  let children = tools.background_children()
  children.sort()
  assert_eq(children, [("subagent-1", "completed"), ("subagent-2", "completed")])
}

///|
async test "interactive_child_answer_deadline_times_out" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=40L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="blocked?", default=None),
    finish_text="proceeded without the answer",
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let model = SceneParentModel::SceneParentModel(
    steps=[
      @tk.tk_tool_call_response(
        "subagent",
        "spawn-1",
        args_object([
          ("task", Json::string("t")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("loose")),
        ]),
      ),
      // Parent never answers; the next step is a plain stop.
      @tk.tk_stop_response("parent shrugs"),
    ],
    children=fn() { tools.background_children() },
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go"), "parent_timeout")
    // The deadline fires while the scope (and the child task) is alive.
    @async.sleep(120)
    // A late answer is explicitly refused.
    let late = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        answer_call([
          ("question_id", Json::string("question-1")),
          ("text", Json::string("too late")),
        ]),
      ),
    )
    match late {
      @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
        assert_true(content.contains("expired"))
      _ => fail("expected late answer to be refused")
    }
    let _ = agent.run_turn(@tk.tk_user_msg("next"), "parent_timeout")
    ()
  })
  // The child saw the deadline, not a hang; it finished on its own.
  assert_eq(composer.answers, ["subagent-1=timeout"])
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
}

///|
async test "interactive_wave_cancel_kills_child_and_closes_question" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=60000L)
  let ask_started : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="stalling?", default=None),
    finish_text="never reached",
    ask_delay_ms=40,
    ask_started=Some(ask_started),
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let model = SceneParentModel::SceneParentModel(
    steps=[@tk.tk_stop_response("parent done")],
    children=fn() { tools.background_children() },
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let scope : @posoco.EventScope = {
    session_id: @posoco.SessionId::unchecked("parent_cancel"),
    run_id: @posoco.RunId::unchecked("run-1"),
    turn_id: @posoco.TurnId::unchecked("turn-1"),
  }
  @posoco.Observer::on_event(tools, Some(scope), @posoco.TurnEvent::TurnStarted)
  parent.run_scoped(async fn(agent) {
    // Part 1: wave cancellation reaches the race while it is still armed
    // (the child's ask has not registered yet). The spawn coroutine must
    // die, the child task must be killed with it.
    @async.with_task_group(group => {
      let task = group.spawn(async fn() {
        @posoco.ToolProvider::execute(
          tools,
          test_ctx(
            agent_call(
              args_object([
                ("task", Json::string("will be cancelled")),
                ("background", Json::boolean(false)),
                ("kind", Json::string("loose")),
              ]),
            ),
          ),
        )
      })
      // Wait for the child tool tree to start, then cancel during its
      // delayed ask (before question registration). A fixed 10ms sleep
      // could cancel core while it was still initializing its task group.
      ignore(@async.with_timeout(5000, () => ask_started.get()))
      task.cancel()
      let cancelled : Bool = try {
        ignore(task.wait())
        false
      } catch {
        _ => true
      }
      assert_true(cancelled)
    })
    @async.sleep(80)
    // Part 2: a live parked question closed by reject: the child's ask
    // wakes with a typed cancellation and the child finishes on its own.
    let receipt = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("asks then gets rejected")),
            ("background", Json::boolean(false)),
            ("kind", Json::string("loose")),
          ]),
        ),
      ),
    )
    assert_true(receipt is @posoco.ToolOutcome::Success(_))
    tools.question.reject_child("subagent-2")
    @async.sleep(50)
    assert_eq(composer.answers, ["subagent-2=cancelled"])
    // The closed question cannot be answered afterwards.
    let late = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        answer_call([
          ("question_id", Json::string("question-2")),
          ("text", Json::string("nope")),
        ]),
      ),
    )
    assert_true(late is @posoco.ToolOutcome::ToolReportedError(_))
    // Part 3: the spawn machinery is reusable — a non-interactive child
    // completes synchronously on the same tool provider.
    let again = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("plain work")),
            ("background", Json::boolean(false)),
            ("kind", Json::string("loose")),
            ("tools", Json::array([Json::string("grep")])),
          ]),
        ),
      ),
    )
    assert_true(again is @posoco.ToolOutcome::Success(_))
    // One ordinary turn delivers the cancelled children's envelopes.
    let _ = agent.run_turn(@tk.tk_user_msg("next"), "parent_cancel")
    ()
  })
  let children = tools.background_children()
  assert_eq(children.length(), 3)
  // With the cancellation cleanup live, the cancelled race's child dies and
  // delivers its cancelled envelope on the ordinary turn above — no
  // tolerant "running" fallback anymore.
  assert_true(children.contains(("subagent-1", "cancelled")))
  assert_true(
    children.contains(("subagent-2", "cancelled")) ||
    children.contains(("subagent-2", "completed")),
  )
  assert_true(children.contains(("subagent-3", "completed")))
}

///|
/// Acceptance 4 (lazy half): a background child's question lands in the
/// injection queue, surfaces as a [subagent-question] envelope on the
/// parent's next ordinary turn, and the answer continues the child in its
/// original session.
async test "background_child_question_roundtrip_lazy_injection" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=5000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="need a fact", default=None),
    finish_text="done with the fact",
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let model = SceneParentModel::SceneParentModel(
    steps=[
      @tk.tk_tool_call_response(
        "subagent",
        "spawn-bg",
        args_object([
          ("task", Json::string("work then ask")),
          ("kind", Json::string("loose")),
          ("background", Json::boolean(true)),
        ]),
      ),
      @tk.tk_stop_response("turn one done"),
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-1",
        args_object([
          ("question_id", Json::string("question-1")),
          ("text", Json::string("fact-from-envelope")),
        ]),
      ),
      @tk.tk_stop_response("turn two done"),
    ],
    children=fn() { tools.background_children() },
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go"), "parent_bg_ask")
    @async.sleep(60)
    let _ = agent.run_turn(@tk.tk_user_msg("next"), "parent_bg_ask")
    @async.sleep(60)
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_bg_ask")
    ()
  })
  // Turn two's first chat saw the injected envelope (not the tool receipt:
  // background asks never ride a wave).
  assert_true(model.inputs[2].contains("[subagent-question"))
  assert_true(model.inputs[2].contains("need a fact"))
  assert_true(model.inputs[2].contains("question-1"))
  assert_eq(model.states[2], [("subagent-1", "waiting_reply")])
  assert_eq(composer.answers, ["subagent-1=fact-from-envelope"])
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
  assert_true(
    model.inputs[model.inputs.length() - 1].contains("done with the fact"),
  )
}

///|
/// Acceptance 5 (background variant): two background children both queue
/// questions; one turn carries both envelopes; answers do not cross.
async test "two_background_children_questions_do_not_cross" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=5000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="need a fact", default=None),
    finish_text="done",
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let model = SceneParentModel::SceneParentModel(
    steps=[
      @tk.tk_tool_call_response(
        "subagent",
        "spawn-a",
        args_object([
          ("task", Json::string("first worker")),
          ("kind", Json::string("loose")),
          ("background", Json::boolean(true)),
        ]),
      ),
      @tk.tk_tool_call_response(
        "subagent",
        "spawn-b",
        args_object([
          ("task", Json::string("second worker")),
          ("kind", Json::string("loose")),
          ("background", Json::boolean(true)),
        ]),
      ),
      @tk.tk_stop_response("turn one done"),
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-1",
        args_object([
          ("question_id", Json::string("question-1")),
          ("text", Json::string("fact-one")),
        ]),
      ),
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-2",
        args_object([
          ("question_id", Json::string("question-2")),
          ("text", Json::string("fact-two")),
        ]),
      ),
      @tk.tk_stop_response("turn two done"),
    ],
    children=fn() { tools.background_children() },
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go"), "parent_bg_two")
    @async.sleep(80)
    let _ = agent.run_turn(@tk.tk_user_msg("next"), "parent_bg_two")
    @async.sleep(80)
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_bg_two")
    ()
  })
  // One injected message carried both envelopes before any answer existed.
  assert_true(model.inputs[3].contains("question-1"))
  assert_true(model.inputs[3].contains("question-2"))
  let sorted_answers = composer.answers.copy()
  sorted_answers.sort()
  assert_eq(sorted_answers, ["subagent-1=fact-one", "subagent-2=fact-two"])
  let children = tools.background_children()
  assert_eq(children, [("subagent-1", "completed"), ("subagent-2", "completed")])
}

///|
/// The M2-deferred case: an interactive child's SECOND question (asked
/// after its first was answered and the parent's turn ended) has no live
/// race to carry it — it flows through the injection queue like a
/// background ask.
async test "interactive_child_second_question_flows_through_queue" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=5000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="later?", default=None),
    finish_text="all answered",
    ask_delay_ms=400,
    asks=2,
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let model = SceneParentModel::SceneParentModel(
    steps=[
      @tk.tk_tool_call_response(
        "subagent",
        "spawn-1",
        args_object([
          ("task", Json::string("two questions")),
          ("background", Json::boolean(false)),
          ("kind", Json::string("loose")),
        ]),
      ),
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-1",
        args_object([
          ("question_id", Json::string("question-1")),
          ("text", Json::string("first-answer")),
        ]),
      ),
      @tk.tk_stop_response("turn one done"),
      @tk.tk_tool_call_response(
        "answer_question",
        "answer-2",
        args_object([
          ("question_id", Json::string("question-2")),
          ("text", Json::string("second-answer")),
        ]),
      ),
      @tk.tk_stop_response("turn two done"),
    ],
    children=fn() { tools.background_children() },
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go"), "parent_second_q")
    // Turn one ends around the first answer (~400ms); the child's second
    // ask registers ~400ms later, safely after the turn and before the
    // next driven turn below — the second question queues with the parent
    // idle.
    @async.sleep(900)
    let _ = agent.run_turn(@tk.tk_user_msg("next"), "parent_second_q")
    @async.sleep(60)
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_second_q")
    ()
  })
  // The first question rode the in-wave receipt...
  assert_true(model.inputs[1].contains("status: waiting_reply"))
  assert_true(model.inputs[1].contains("question-1"))
  // ...the second arrived as an injected envelope on a later turn.
  assert_true(model.inputs[3].contains("[subagent-question"))
  assert_true(model.inputs[3].contains("question-2"))
  assert_eq(composer.answers, [
    "subagent-1=first-answer", "subagent-1=second-answer",
  ])
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
}

// ---------------------------------------------------------------------------
// Background by default + `stop_subagent`: a spawn that omits `background`
// is an Agent-owned background task (only an explicit `false` blocks), and
// the parent can stop one child on its own without touching its turn, its
// siblings, or the child's authoritative terminal (which still arrives
// exactly once through the existing delivery channel).
// ---------------------------------------------------------------------------

///|
/// One model response with two `subagent` calls that OMIT `background`: both
/// children take the default (background) path.
fn two_background_wave(
  first_task : String,
  second_task : String,
) -> @posoco.ModelCallResult {
  let calls : Array[@posoco.ToolCall] = [
    {
      call_id: @posoco.CallId::unchecked("bg-wave-a"),
      name: @posoco.ToolName::unchecked("subagent"),
      arguments: args_object([("task", Json::string(first_task))]),
    },
    {
      call_id: @posoco.CallId::unchecked("bg-wave-b"),
      name: @posoco.ToolName::unchecked("subagent"),
      arguments: args_object([("task", Json::string(second_task))]),
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
/// Scope used by the tests that drive the tool provider directly while still
/// needing a parent session (background spawns address their result to it).
fn direct_scope(session : String) -> @posoco.EventScope {
  {
    session_id: @posoco.SessionId::unchecked(session),
    run_id: @posoco.RunId::unchecked("run-1"),
    turn_id: @posoco.TurnId::unchecked("turn-1"),
  }
}

///|
async test "omitted_background_defaults_to_background_receipt_and_delivery" {
  let composer = FakeComposer::FakeComposer(response_text="child did the thing")
  let tools = test_tools(composer=composer as &ChildComposer)
  let model = SceneParentModel::SceneParentModel(
    steps=[
      // No `background` argument at all: the default must be background.
      @tk.tk_tool_call_response(
        "subagent",
        "spawn-default",
        args_object([("task", Json::string("dig"))]),
      ),
      @tk.tk_stop_response("turn one done"),
      @tk.tk_stop_response("turn two done"),
    ],
    children=fn() { tools.background_children() },
  )
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let parent = build_parent_agent(tools, model as &@posoco.ModelPort, store)
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go dig"), "parent_default_bg")
    // The receipt came back in-wave, before the child's result existed.
    assert_true(model.inputs[1].contains("background subagent accepted"))
    assert_true(model.inputs[1].contains("child_session: subagent-1"))
    assert_eq(model.states[1], [("subagent-1", "running")])
    @async.sleep(300)
    let _ = agent.run_turn(@tk.tk_user_msg("again"), "parent_default_bg")
  })
  // The child's terminal travelled the ordinary follow-up turn.
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
  assert_true(
    store_contains_user_text(
      store, "parent_default_bg", "[posoco-task-outcome id=",
    ),
  )
  assert_true(any_input_contains(model.inputs, "child did the thing"))
}

///|
async test "omitted_background_requires_the_composed_task_capability" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(agent_call(args_object([("task", Json::string("t"))]))),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(
        content.contains(
          "background mode requires the composed task capability",
        ),
      )
    _ => fail("expected the default background path to be refused")
  }
  // A refused call consumes no budget slot.
  assert_eq(tools.ledger.acquired().length(), 0)
}

///|
async test "stop_subagent_reports_argument_and_unknown_id_errors" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let missing = @posoco.ToolProvider::execute(
    tools,
    test_ctx({
      call_id: @posoco.CallId::unchecked("stop-missing"),
      name: @posoco.ToolName::unchecked("stop_subagent"),
      arguments: args_object([]),
    }),
  )
  assert_true(
    outcome_content(missing).contains("missing required 'child_session'"),
  )
  let empty = @posoco.ToolProvider::execute(tools, test_ctx(stop_call("  ")))
  assert_true(
    outcome_content(empty).contains(
      "'child_session' must be a non-empty string",
    ),
  )
  let wrong_type = @posoco.ToolProvider::execute(
    tools,
    test_ctx({
      call_id: @posoco.CallId::unchecked("stop-type"),
      name: @posoco.ToolName::unchecked("stop_subagent"),
      arguments: args_object([("child_session", Json::number(1.0))]),
    }),
  )
  assert_true(outcome_content(wrong_type).contains("must be a string"))
  // Unknown id on an empty registry: explicit, and it says what is known.
  let unknown = @posoco.ToolProvider::execute(
    tools,
    test_ctx(stop_call("subagent-9")),
  )
  assert_true(
    outcome_content(unknown).contains("unknown child_session 'subagent-9'"),
  )
  assert_true(outcome_content(unknown).contains("(none spawned yet)"))
  // With one known child, the refusal lists it (owned children only).
  seed_undelivered(tools, task_id="task_1", child_session="subagent-1")
  let unknown_with_known = @posoco.ToolProvider::execute(
    tools,
    test_ctx(stop_call("subagent-9")),
  )
  assert_true(outcome_content(unknown_with_known).contains("subagent-1"))
  assert_true(unknown_with_known is @posoco.ToolOutcome::ToolReportedError(_))
}

///|
async test "stop_subagent_refuses_a_foreground_run_without_a_handle" {
  let probe = ConcurrencyProbeModel::new()
  let composer = FakeComposer::FakeComposer(
    response_text="unused",
    slow_model=Some(probe as &@posoco.ModelPort),
  )
  let tools = test_tools(composer=composer as &ChildComposer)
  @async.with_task_group(async fn(group) {
    let foreground = group.spawn(async fn() {
      @posoco.ToolProvider::execute(
        tools,
        test_ctx(
          agent_call(
            args_object([
              ("task", Json::string("blocking run")),
              ("background", Json::boolean(false)),
            ]),
          ),
        ),
      )
    })
    ignore(probe.entered.get())
    // The child is running, but it belongs to the spawning tool call: there
    // is no separate handle, and the refusal must say so instead of
    // pretending a cancellation was requested.
    let stopped = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    match stopped {
      @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
        assert_true(content.contains("no stoppable handle"))
        assert_true(content.contains("background=false"))
      }
      _ => fail("expected the foreground run to be refused")
    }
    probe.release.put(())
    assert_true(foreground.wait() is @posoco.ToolOutcome::Success(_))
  })
}

///|
/// The core stop contract: only the named child dies, siblings and the parent
/// keep running, the slot of the stopped run is released, the authoritative
/// terminal is `cancelled` and arrives exactly once, and a repeated stop
/// reports the request it already made.
async test "stop_subagent_cancels_only_the_named_child" {
  let events : Array[@kit.SubagentEvent] = []
  let probe = ConcurrencyProbeModel::new()
  let composer = FakeComposer::FakeComposer(
    response_text="unused",
    slow_model=Some(probe as &@posoco.ModelPort),
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_global_concurrency(2),
    observers=[fn(event) { events.push(event) }],
  )
  let model = SceneParentModel::SceneParentModel(
    steps=[
      two_background_wave("first worker", "second worker"),
      @tk.tk_stop_response("turn one done"),
      @tk.tk_tool_call_response(
        "stop_subagent",
        "stop-1",
        args_object([("child_session", Json::string("subagent-1"))]),
      ),
      @tk.tk_stop_response("turn two done"),
      @tk.tk_stop_response("turn three done"),
    ],
    children=fn() { tools.background_children() },
  )
  let parent = build_parent_agent(
    tools,
    model as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(agent) {
    let _ = agent.run_turn(@tk.tk_user_msg("go"), "parent_stop")
    // Both default-background children are live and inside their model call.
    ignore(probe.entered.get())
    ignore(probe.entered.get())
    assert_eq(probe.peak, 2)
    assert_eq(tools.background_children(), [
      ("subagent-1", "running"),
      ("subagent-2", "running"),
    ])
    let _ = agent.run_turn(@tk.tk_user_msg("stop the first"), "parent_stop")
    // A second stop is idempotent: the request is reported, not re-issued.
    let again = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    let again_text = outcome_content(again)
    assert_false(again_text.contains("status: cancellation_requested"))
    assert_true(
      again_text.contains("status: cancellation_already_requested") ||
      again_text.contains("status: already_finished"),
    )
    @async.sleep(300)
    // The stopped run released its slot; the sibling still holds its own.
    assert_true(tools.global_slots.try_acquire())
    assert_false(tools.global_slots.try_acquire())
    tools.global_slots.release()
    // The terminal travels the ordinary delivery turn, for that child only.
    let _ = agent.run_turn(@tk.tk_user_msg("next"), "parent_stop")
    assert_eq(tools.background_children(), [
      ("subagent-1", "cancelled"),
      ("subagent-2", "running"),
    ])
  })
  // The two children were requested, and no extra spawn happened.
  assert_eq(composer.specs.length(), 2)
  assert_true(any_input_contains(model.inputs, "cancellation_requested"))
  assert_true(any_input_contains(model.inputs, "label=subagent-1: cancelled"))
  // Exactly one authoritative terminal for the stopped child, and no terminal
  // for the sibling that is still running when the scope ends.
  let terminals = custom_payloads(events, want="background_terminal")
  assert_eq(terminals.length(), 1)
  assert_eq(json_string_field(terminals[0], "child_session"), "subagent-1")
  assert_eq(json_string_field(terminals[0], "state"), "cancelled")
  // Returning from the scope killed the survivor; its slot is back too.
  assert_true(tools.global_slots.try_acquire())
  tools.global_slots.release()
}

///|
/// A stopped child's parked question is closed before the coroutine unwinds:
/// the answer is refused with the cancellation reason, the queued envelope is
/// dropped instead of being injected on a later turn, and the child observed a
/// cancelled ask rather than an answer.
async test "stop_subagent_closes_questions_and_blocks_late_answers" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=60000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="stop me?", default=None),
    finish_text="never reached",
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let parent = build_parent_agent(
    tools,
    @tk.ScriptedModel([]) as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(_agent) {
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_stop_q")),
      @posoco.TurnEvent::TurnStarted,
    )
    // No `background` argument: the default already runs it as a task.
    let spawned = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("ask then wait")),
            ("kind", Json::string("loose")),
          ]),
        ),
      ),
    )
    assert_true(spawned is @posoco.ToolOutcome::Success(_))
    let task_id = outcome_field(spawned, "task_id")
    assert_true(task_id != "")
    @async.sleep(300)
    // The child's ask queued itself (no live race carried it).
    let injected = tools.inject_queued_questions([])
    assert_eq(injected.length(), 1)
    let injected_text = message_text(injected[0])
    assert_true(injected_text.contains("[subagent-question"))
    assert_true(injected_text.contains("question-1"))
    assert_eq(tools.background_children(), [("subagent-1", "waiting_reply")])
    let stopped = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    assert_true(
      outcome_content(stopped).contains("status: cancellation_requested"),
    )
    // Nothing of the run can be answered or injected any more.
    assert_eq(tools.background_children(), [("subagent-1", "running")])
    let late = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        answer_call([
          ("question_id", Json::string("question-1")),
          ("text", Json::string("too late")),
        ]),
      ),
    )
    match late {
      @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
        assert_true(content.contains("cancelled"))
      _ => fail("expected the stopped question to be refused")
    }
    assert_eq(tools.inject_queued_questions([]).length(), 0)
    @async.sleep(300)
    // The child saw its ask cancelled and died; the authoritative terminal is
    // the ordinary delivered `cancelled` envelope, exactly once.
    assert_eq(composer.answers, ["subagent-1=cancelled"])
    tools.observe_deliveries([
      outcome_envelope(task_id~, detail="cancelled: task cancelled"),
    ])
    assert_eq(tools.background_children(), [("subagent-1", "cancelled")])
  })
}

///|
/// Stop, then resume the same child session: the new run replaces the old
/// record, arms a fresh question race, and the new question is answerable —
/// the stopped run's questions and handles do not swallow it.
async test "stop_then_resume_arms_a_fresh_run_and_question" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=60000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="again?", default=None),
    finish_text="second run done",
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let parent = build_parent_agent(
    tools,
    @tk.ScriptedModel([]) as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(_agent) {
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_stop_resume")),
      @posoco.TurnEvent::TurnStarted,
    )
    let spawned = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("ask then wait")),
            ("kind", Json::string("loose")),
          ]),
        ),
      ),
    )
    let first_task_id = outcome_field(spawned, "task_id")
    @async.sleep(300)
    assert_eq(tools.inject_queued_questions([]).length(), 1)
    let stopped = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    assert_true(outcome_content(stopped).contains("cancellation_requested"))
    @async.sleep(300)
    // Foreground resume of the SAME child session: a fresh interactive race,
    // so the first question of the new run comes back in-wave.
    let resumed = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("ask again")),
            ("kind", Json::string("loose")),
            ("resume", Json::string("subagent-1")),
            ("background", Json::boolean(false)),
          ]),
        ),
      ),
    )
    let resumed_text = outcome_content(resumed)
    assert_true(resumed_text.contains("waiting_reply"))
    assert_true(resumed_text.contains("question-2"))
    let answered = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        answer_call([
          ("question_id", Json::string("question-2")),
          ("text", Json::string("fresh answer")),
        ]),
      ),
    )
    assert_true(answered is @posoco.ToolOutcome::Success(_))
    @async.sleep(300)
    // The stopped run was cancelled, the resumed one was answered and ran on.
    assert_eq(composer.answers, [
      "subagent-1=cancelled", "subagent-1=fresh answer",
    ])
    // The retained handle belongs to the NEW run, with no stale cancel flag.
    match tools.live.get("subagent-1") {
      Some(entry) => {
        assert_true(entry.task_id != first_task_id)
        assert_false(entry.cancel_requested)
      }
      None => fail("expected the resumed run's handle to be retained")
    }
  })
}

///|
/// Real state, never a fake success: a child that already exited (before or
/// after its terminal was delivered) reports that instead of a cancellation.
async test "stop_subagent_reports_finished_states_truthfully" {
  let composer = FakeComposer::FakeComposer(response_text="finished fast")
  let tools = test_tools(composer=composer as &ChildComposer)
  let parent = build_parent_agent(
    tools,
    @tk.ScriptedModel([]) as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(_agent) {
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_stop_finished")),
      @posoco.TurnEvent::TurnStarted,
    )
    let spawned = @posoco.ToolProvider::execute(
      tools,
      test_ctx(agent_call(args_object([("task", Json::string("quick"))]))),
    )
    assert_true(spawned is @posoco.ToolOutcome::Success(_))
    let task_id = outcome_field(spawned, "task_id")
    @async.sleep(300)
    // Exited, terminal not delivered yet: not stoppable, and the receipt says
    // so instead of claiming a cancellation.
    let before_delivery = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    assert_true(
      outcome_content(before_delivery).contains("status: already_finished"),
    )
    assert_true(outcome_content(before_delivery).contains("already exited"))
    // After delivery the terminal state is the truthful answer.
    tools.observe_deliveries([
      outcome_envelope(task_id~, detail="finished fast"),
    ])
    assert_eq(tools.background_children(), [("subagent-1", "completed")])
    let after_delivery = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    assert_true(
      outcome_content(after_delivery).contains("status: already_finished"),
    )
    assert_true(outcome_content(after_delivery).contains("state: completed"))
    // The handle is gone: nothing is left that could be cancelled.
    assert_true(tools.live.get("subagent-1") is None)
  })
}

///|
/// Completion racing a stop: whichever side wins, the receipt must stay
/// truthful (a stop only claims a request it actually issued) and the run can
/// never be cancelled twice — the exit marker removes it from the stoppable
/// set before the authoritative terminal is even delivered.
async test "stop_racing_an_immediate_completion_never_double_requests" {
  let probe = ConcurrencyProbeModel::new()
  let composer = FakeComposer::FakeComposer(
    response_text="unused",
    slow_model=Some(probe as &@posoco.ModelPort),
  )
  let tools = test_tools(composer=composer as &ChildComposer)
  let parent = build_parent_agent(
    tools,
    @tk.ScriptedModel([]) as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(_agent) {
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_stop_race")),
      @posoco.TurnEvent::TurnStarted,
    )
    let spawned = @posoco.ToolProvider::execute(
      tools,
      test_ctx(agent_call(args_object([("task", Json::string("racy"))]))),
    )
    assert_true(spawned is @posoco.ToolOutcome::Success(_))
    ignore(probe.entered.get())
    // Release the child and stop it in the same synchronous window: the two
    // orderings are both legitimate, so the assertions below only pin what
    // must hold either way.
    probe.release.put(())
    let stop = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    let status = outcome_field(stop, "status")
    assert_true(
      status == "cancellation_requested" || status == "already_finished",
    )
    @async.sleep(300)
    // The run left the stoppable set exactly once: no second request, ever.
    let second = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    assert_false(
      outcome_content(second).contains("status: cancellation_requested"),
    )
    match tools.live.get("subagent-1") {
      Some(entry) => assert_true(entry.exited)
      None => ()
    }
  })
}

///|
/// `resume` follows the same default as a fresh spawn: omitting `background`
/// continues the existing child session as an Agent-owned background task.
async test "resume_omitting_background_takes_the_background_default" {
  let composer = FakeComposer::FakeComposer(response_text="resumed fine")
  let tools = test_tools(composer=composer as &ChildComposer)
  let parent = build_parent_agent(
    tools,
    @tk.ScriptedModel([]) as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(_agent) {
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_resume_default")),
      @posoco.TurnEvent::TurnStarted,
    )
    // A foreground run creates the resumable child session.
    let first = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("first pass")),
            ("background", Json::boolean(false)),
          ]),
        ),
      ),
    )
    assert_true(first is @posoco.ToolOutcome::Success(_))
    @async.sleep(50)
    let resumed = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("second pass")),
            ("resume", Json::string("subagent-1")),
          ]),
        ),
      ),
    )
    assert_true(
      outcome_content(resumed).contains("background subagent accepted"),
    )
    assert_eq(outcome_field(resumed, "child_session"), "subagent-1")
    assert_true(outcome_field(resumed, "task_id") != "")
    // One child session, two runs: the resumed one owns the live handle.
    assert_eq(composer.specs.length(), 2)
    assert_true(composer.specs[1].resuming)
    assert_true(tools.live.get("subagent-1") is Some(_))
  })
}

///|
/// The run identity guard, end to end: stop a run, resume the same child
/// session, let the new run ask, and only then deliver the stopped run's
/// `cancelled` envelope. The old terminal is still delivered exactly once as
/// its own run's terminal, but it must not disarm the new run, close its
/// question, or rewrite its state.
async test "superseded_terminal_never_pollutes_the_resumed_run" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=60000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="still there?", default=None),
    finish_text="second run done",
  )
  let events : Array[@kit.SubagentEvent] = []
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
    observers=[fn(event) { events.push(event) }],
  )
  let parent = build_parent_agent(
    tools,
    @tk.ScriptedModel([]) as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(_agent) {
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_superseded")),
      @posoco.TurnEvent::TurnStarted,
    )
    let spawned = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("ask then wait")),
            ("kind", Json::string("loose")),
          ]),
        ),
      ),
    )
    let first_task_id = outcome_field(spawned, "task_id")
    assert_true(first_task_id != "")
    @async.sleep(300)
    // Run one's ask queued itself (no live race carried it).
    assert_eq(tools.inject_queued_questions([]).length(), 1)
    let stopped = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    assert_true(
      outcome_content(stopped).contains("status: cancellation_requested"),
    )
    @async.sleep(300)
    // Resume the same child session as the default background run.
    let resumed = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("ask again")),
            ("kind", Json::string("loose")),
            ("resume", Json::string("subagent-1")),
          ]),
        ),
      ),
    )
    let second_task_id = outcome_field(resumed, "task_id")
    assert_true(second_task_id != "")
    assert_true(second_task_id != first_task_id)
    @async.sleep(300)
    let injected = tools.inject_queued_questions([])
    assert_eq(injected.length(), 1)
    assert_true(message_text(injected[0]).contains("question-2"))
    assert_eq(tools.background_children(), [("subagent-1", "waiting_reply")])
    // Only now does the stopped run's envelope arrive.
    tools.observe_deliveries([
      outcome_envelope(
        task_id=first_task_id,
        detail="cancelled: cancelled by the parent",
      ),
    ])
    // Delivered once, as its own run's terminal ...
    let terminals = custom_payloads(events, want="background_terminal")
    assert_eq(terminals.length(), 1)
    assert_eq(json_string_field(terminals[0], "task_id"), first_task_id)
    assert_eq(json_string_field(terminals[0], "state"), "cancelled")
    assert_true(json_bool_field(terminals[0], "superseded"))
    // ... and nothing of the resumed run was touched.
    assert_eq(tools.background_children(), [("subagent-1", "waiting_reply")])
    match tools.live.get("subagent-1") {
      Some(entry) => {
        assert_eq(entry.task_id, second_task_id)
        assert_false(entry.cancel_requested)
        assert_false(entry.exited)
      }
      None => fail("the resumed run must still own its handle")
    }
    // The new question was not closed with the old run's terminal.
    let answered = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        answer_call([
          ("question_id", Json::string("question-2")),
          ("text", Json::string("still here")),
        ]),
      ),
    )
    assert_true(answered is @posoco.ToolOutcome::Success(_))
    @async.sleep(300)
    assert_eq(composer.answers, [
      "subagent-1=cancelled", "subagent-1=still here",
    ])
    // The resumed run's own terminal still lands normally.
    tools.observe_deliveries([
      outcome_envelope(task_id=second_task_id, detail="second run done"),
    ])
    assert_eq(tools.background_children(), [("subagent-1", "completed")])
    assert_true(tools.live.get("subagent-1") is None)
    assert_eq(custom_payloads(events, want="background_terminal").length(), 2)
  })
}

///|
/// A refused submit admitted no work: the record registered before the
/// hand-off is rolled back instead of leaving a ghost child — and a refused
/// resume keeps the terminal state of the run it was continuing.
async test "submit_failure_leaves_no_ghost_registry_record" {
  let composer = FakeComposer::FakeComposer(response_text="never runs")
  let tools = test_tools(composer=composer as &ChildComposer)
  tools.tasks = Some(
    @posoco.Tasks::from_submit(submit=fn(
      _spec : @posoco.TaskSpec,
    ) -> Result[@posoco.TaskHandle, @posoco.TaskSubmitError] {
      Err(@posoco.TaskSubmitError::QueueFull)
    }),
  )
  @posoco.Observer::on_event(
    tools,
    Some(direct_scope("parent_ghost")),
    @posoco.TurnEvent::TurnStarted,
  )
  let refused = @posoco.ToolProvider::execute(
    tools,
    test_ctx(agent_call(args_object([("task", Json::string("quick"))]))),
  )
  assert_true(outcome_content(refused).contains("background subagent refused"))
  assert_true(outcome_content(refused).contains("task queue is full"))
  // No ghost: the child never existed, so nothing lists it ...
  assert_eq(tools.background_children(), [])
  assert_true(tools.live.get("subagent-1") is None)
  // ... and a resume of that id is rejected instead of "accepted".
  let resume_of_ghost = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("again")),
          ("resume", Json::string("subagent-1")),
        ]),
      ),
    ),
  )
  assert_true(
    outcome_content(resume_of_ghost).contains("unknown resume id 'subagent-1'"),
  )
  // A refused resume keeps the previous run's recorded terminal.
  seed_undelivered(tools, task_id="task_1", child_session="subagent-2")
  match tools.registry.get("subagent-2") {
    Some(record) => record.state = Done("completed", "previous run")
    None => fail("expected the seeded record")
  }
  let refused_resume = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("continue")),
          ("resume", Json::string("subagent-2")),
        ]),
      ),
    ),
  )
  assert_true(
    outcome_content(refused_resume).contains("background subagent refused"),
  )
  assert_eq(tools.background_children(), [("subagent-2", "completed")])
}

///|
/// An interactive foreground run that finishes without ever asking must
/// release its race waiter: otherwise the resumed background run's question is
/// handed to a cell nobody waits on — neither returned in-wave nor queued — and
/// the parent never sees it.
async test "foreground_finish_without_a_question_keeps_the_resume_question" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=60000L)
  let composer = AskingComposer::AskingComposer(
    channel=broker.channel(),
    req=@posoco.UiRequest::Input(prompt="resumed ask?", default=None),
    finish_text="quiet run done",
    asks_per_run=[0, 1],
  )
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
    question=Some(broker),
  )
  let parent = build_parent_agent(
    tools,
    @tk.ScriptedModel([]) as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(_agent) {
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_quiet_first")),
      @posoco.TurnEvent::TurnStarted,
    )
    // Run one: blocking foreground, interactive face, and it never asks.
    let first = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("just work")),
            ("kind", Json::string("loose")),
            ("background", Json::boolean(false)),
          ]),
        ),
      ),
    )
    assert_true(outcome_content(first).contains("child_session: subagent-1"))
    assert_eq(tools.background_children(), [("subagent-1", "completed")])
    // The finished run owns neither a race waiter nor a handle any more.
    assert_true(broker.armed.get("subagent-1") is None)
    assert_true(tools.live.get("subagent-1") is None)
    // Its resume takes the background default and asks one question: that
    // question must reach the injection queue of the parent.
    let resumed = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        agent_call(
          args_object([
            ("task", Json::string("ask now")),
            ("kind", Json::string("loose")),
            ("resume", Json::string("subagent-1")),
          ]),
        ),
      ),
    )
    assert_true(
      outcome_content(resumed).contains("background subagent accepted"),
    )
    let task_id = outcome_field(resumed, "task_id")
    @async.sleep(300)
    let injected = tools.inject_queued_questions([])
    assert_eq(injected.length(), 1)
    assert_true(message_text(injected[0]).contains("question-1"))
    assert_eq(tools.background_children(), [("subagent-1", "waiting_reply")])
    let answered = @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        answer_call([
          ("question_id", Json::string("question-1")),
          ("text", Json::string("later answer")),
        ]),
      ),
    )
    assert_true(answered is @posoco.ToolOutcome::Success(_))
    @async.sleep(300)
    assert_eq(composer.answers, ["subagent-1=later answer"])
    tools.observe_deliveries([
      outcome_envelope(task_id~, detail="quiet run done"),
    ])
    assert_eq(tools.background_children(), [("subagent-1", "completed")])
  })
}

///|
/// Ownership boundary: a child belongs to the parent session that spawned it,
/// so a stop arriving from another session is refused before anything is
/// cancelled — and the same call from the spawning session is a real request.
async test "stop_refuses_a_child_spawned_by_another_parent_session" {
  let probe = ConcurrencyProbeModel::new()
  let composer = FakeComposer::FakeComposer(
    response_text="unused",
    slow_model=Some(probe as &@posoco.ModelPort),
  )
  let tools = test_tools(composer=composer as &ChildComposer)
  let parent = build_parent_agent(
    tools,
    @tk.ScriptedModel([]) as &@posoco.ModelPort,
    @tk.RecordingSessionPort::RecordingSessionPort(),
  )
  let _ = parent.run_scoped(async fn(_agent) {
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_owner_a")),
      @posoco.TurnEvent::TurnStarted,
    )
    let spawned = @posoco.ToolProvider::execute(
      tools,
      test_ctx(agent_call(args_object([("task", Json::string("mine"))]))),
    )
    assert_true(spawned is @posoco.ToolOutcome::Success(_))
    ignore(probe.entered.get())
    // Another parent session may not stop this run.
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_owner_b")),
      @posoco.TurnEvent::TurnStarted,
    )
    let foreign = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    match foreign {
      @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
        assert_true(content.contains("parent_owner_a"))
        assert_true(content.contains("parent_owner_b"))
      }
      _ => fail("expected a cross-session stop to be refused")
    }
    // Nothing was cancelled, and nothing claims otherwise.
    match tools.live.get("subagent-1") {
      Some(entry) => assert_false(entry.cancel_requested)
      None => fail("expected the run to still be live")
    }
    assert_eq(tools.background_children(), [("subagent-1", "running")])
    // From the spawning session the same call is a real request.
    @posoco.Observer::on_event(
      tools,
      Some(direct_scope("parent_owner_a")),
      @posoco.TurnEvent::TurnStarted,
    )
    let own = @posoco.ToolProvider::execute(
      tools,
      test_ctx(stop_call("subagent-1")),
    )
    assert_true(outcome_content(own).contains("status: cancellation_requested"))
    @async.sleep(100)
  })
}
