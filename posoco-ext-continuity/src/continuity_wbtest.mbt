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
test "extension composes through existing posoco ports" {
  let model = @posoco.ScriptedModel([])
  let ext = continuity_extension(model as &@posoco.ModelPort)
  let manifest = ext.manifest()
  assert_eq(manifest.models.length(), 1)
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.observers.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
  assert_eq(manifest.sessions.length(), 0)
}
