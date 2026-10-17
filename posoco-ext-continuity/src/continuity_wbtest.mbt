///|
test "budget classification follows thresholds" {
  let config = ContinuityConfig::default()
  assert_eq(classify_budget(100, 1000, config).state, Normal)
  assert_eq(classify_budget(600, 1000, config).state, Prepare)
  assert_eq(classify_budget(750, 1000, config).state, CheckpointNeeded)
  assert_eq(classify_budget(900, 1000, config).state, Emergency)
}

///|
test "checkpoint summary requires goal and durable content" {
  let empty : CheckpointSummary = {
    goal: "",
    completed: [],
    decisions: [],
    artifacts: [],
    facts: [],
    open_threads: [],
  }
  assert_false(empty.is_meaningful())
  let useful : CheckpointSummary = {
    goal: "Keep session continuity",
    completed: ["Planner implemented"],
    decisions: [],
    artifacts: [],
    facts: [],
    open_threads: [],
  }
  assert_true(useful.is_meaningful())
}

///|
test "checkpoint rendering labels compact history as non-authoritative" {
  let summary : CheckpointSummary = {
    goal: "Implement continuity",
    completed: ["Added planner"],
    decisions: ["Keep exact history in archive"],
    artifacts: ["src/planner.mbt"],
    facts: ["archive precedes folding"],
    open_threads: ["wire checkpoint prepare and commit"],
  }
  let rendered = summary.render("cp_test")
  assert_true(rendered.contains("<session-checkpoint id=\"cp_test\">"))
  assert_true(rendered.contains("src/planner.mbt"))
  assert_true(rendered.contains("session_history_search/read"))
}

///|
test "continuity prompt tells model to recall exact history" {
  let prompt = ContinuityPrompt::new().system_prompt()
  assert_true(prompt.contains("session_history_search"))
  assert_true(prompt.contains("not authoritative historical evidence"))
}

///|
test "planner keeps small conversations active" {
  let config = ContinuityConfig::default()
  let messages : Array[@posoco.Message] = [
    @posoco.Message::SystemMessage(content=[@posoco.Content::Text("system")]),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hello")]),
  ]
  let plan = plan_continuity(messages, 128000, config)
  assert_eq(plan.budget.state, Normal)
  assert_eq(plan.candidate, None)
}

///|
test "prepared checkpoint rewrites only the exact source range" {
  let old_user = @posoco.tk_user_msg("old user")
  let old_assistant : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("old assistant")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
  let latest = @posoco.tk_user_msg("latest")
  let messages : Array[@posoco.Message] = [
    @posoco.tk_system_msg("system"),
    old_user,
    old_assistant,
    latest,
  ]
  let candidate : RuntimeCandidate = {
    id: "cc_test",
    session_id: "s1",
    run_id: "r1",
    start_index: 1,
    end_index: 3,
    estimated_tokens: 20,
    source_messages: [old_user, old_assistant],
  }
  let prepared : PreparedCheckpoint = {
    checkpoint_id: "cp_test",
    candidate,
    summary: {
      goal: "settled work",
      completed: ["done"],
      decisions: [],
      artifacts: [],
      facts: [],
      open_threads: [],
    },
  }
  match apply_prepared_checkpoint(messages, prepared) {
    None => fail("expected exact source range to rewrite")
    Some(rewritten) => {
      assert_eq(rewritten.length(), 3)
      assert_true(message_text(rewritten[1]).contains("session-checkpoint"))
      assert_true(message_text(rewritten[2]).contains("latest"))
    }
  }
}

///|
test "extension composes through existing posoco ports" {
  let model = @posoco.ScriptedModel([])
  let ext = continuity_extension(model as &@posoco.ModelPort)
  let manifest = ext.manifest()
  assert_eq(manifest.models.length(), 1)
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.observers.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
  assert_eq(manifest.sessions.length(), 0)
}

///|
async test "e2e checkpoint archives rewrites and remains searchable" {
  let checkpoint_args = Json::object(
    Map::from_array([
      ("candidate_id", Json::string("cc_1")),
      ("goal", Json::string("finish historical work")),
      (
        "completed",
        Json::array([Json::string("historical task completed")]),
      ),
      ("decisions", Json::array([])),
      ("artifacts", Json::array([Json::string("src/history.mbt")])),
      ("facts", Json::array([])),
      ("open_threads", Json::array([])),
    ]),
  )
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response(
        "session_checkpoint",
        "checkpoint_call",
        checkpoint_args,
      ),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let config : ContinuityConfig = {
    context_window: 100,
    prepare_ratio: 0.10,
    checkpoint_ratio: 0.20,
    emergency_ratio: 0.95,
    min_recent_messages: 1,
    min_recent_tokens: 1,
    min_checkpoint_tokens: 1,
    search_limit: 8,
    read_page_chars: 6000,
  }
  let continuity = continuity_extension(
    model as &@posoco.ModelPort,
    config~,
  )
  let sessions = @posoco.RecordingSessionStore::RecordingSessionStore()
  sessions.seed(
    "s1",
    {
      messages: [
        @posoco.tk_user_msg(
          "OLD_MARKER_73 historical request with enough text to create pressure",
        ),
        @posoco.Message::AssistantMessage(
          content=[@posoco.Content::Text("historical answer already completed")],
          tool_calls=[],
          reasoning=None,
          finish_reason=@posoco.FinishReason::Stop,
        ),
      ],
      metadata: Map::from_array([]),
    },
  )
  let session_ext = @posoco.tk_ext(id="sessions", sessions=[sessions])
  let agent = @posoco.Agent(
    exts=[continuity, session_ext],
    config=@posoco.tk_config(),
  )
  ignore(agent.run_turn(@posoco.tk_user_msg("continue with new work"), "s1"))

  assert_eq(model.call_count(), 2)
  assert_true(model.received_messages[0].length() > 0)
  let mut first_saw_candidate = false
  for message in model.received_messages[0] {
    if message_text(message).contains(candidate_notice_prefix) {
      first_saw_candidate = true
    }
  }
  assert_true(first_saw_candidate)

  let saved = (sessions as &@posoco.SessionStore).load("s1")
  let mut saw_checkpoint = false
  for message in saved.messages {
    if message_text(message).contains("<session-checkpoint id=\"cp_1\">") {
      saw_checkpoint = true
    }
  }
  assert_true(saw_checkpoint)
  assert_eq(continuity.archive.count("s1"), 2)
  let hits = continuity.archive.search("s1", "OLD_MARKER_73", 8)
  assert_eq(hits.length(), 1)
  match continuity.checkpoint_counts.get("s1") {
    Some(count) => assert_eq(count, 1)
    None => fail("expected committed checkpoint count")
  }
}
