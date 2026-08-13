///|
test "work_snapshot/empty_is_explicitly_unspecified" {
  let work = WorkSnapshot::empty()
  assert_eq(work.objective, None)
  assert_eq(work.current_work, None)
  assert_eq(work.next_action, None)
  assert_eq(work.done_when.length(), 0)
  assert_eq(work.completed.length(), 0)
  assert_eq(work.queue.length(), 0)
}

///|
test "handoff_validation/requires_continuation_anchors" {
  let empty = WorkSnapshot::empty()
  assert_eq(validate_work(empty), Some("handoff requires an objective"))

  let objective_only : WorkSnapshot = {
    ..empty,
    objective: Some("Implement handoff"),
  }
  assert_eq(validate_work(objective_only), Some("handoff requires current_work"))

  let current : WorkSnapshot = {
    ..objective_only,
    current_work: Some("Writing HANDOFF.md renderer"),
  }
  assert_eq(
    validate_work(current),
    Some("handoff requires exactly one next_action"),
  )

  let complete : WorkSnapshot = {
    ..current,
    next_action: Some("Run moon test"),
  }
  assert_eq(validate_work(complete), None)
}

///|
test "handoff_document/renders_continuation_state_not_history" {
  let work : WorkSnapshot = {
    objective: Some("Implement posoco-ext-handoff"),
    done_when: ["HANDOFF.md is deterministic", "No LLM is required"],
    completed: ["Defined the handoff document shape"],
    current_work: Some("Implement the Markdown renderer"),
    next_action: Some("Run moon test"),
    queue: ["Add workspace probe integration"],
    notes: ["Conversation history stays in the Posoco message tree"],
    validation_passed: ["pure renderer fixture"],
    validation_failed: [],
    validation_not_run: ["moon test"],
  }
  let workspace : WorkspaceSnapshot = {
    root: "/repo",
    branch: Some("feat/handoff"),
    head: Some("abc123"),
    changes: [
      { path: "posoco-ext-handoff/src/handoff.mbt", status: "modified" },
      { path: "posoco-ext-handoff/README.mbt.md", status: "modified" },
    ],
  }
  let markdown = render_handoff_document(work, workspace)
  assert_true(markdown.contains("# Handoff"))
  assert_true(markdown.contains("## Objective"))
  assert_true(markdown.contains("## Done When"))
  assert_true(markdown.contains("## Current Work"))
  assert_true(markdown.contains("## Workspace"))
  assert_true(markdown.contains("## Validation"))
  assert_true(markdown.contains("## Next Action"))
  assert_true(markdown.contains("## Queue"))
  assert_true(markdown.contains("Implement the Markdown renderer"))
  assert_true(markdown.contains("`posoco-ext-handoff/src/handoff.mbt` — modified"))
  assert_true(markdown.contains("Run moon test"))
  assert_true(!markdown.contains("source session"))
  assert_true(!markdown.contains("ownership"))
}
