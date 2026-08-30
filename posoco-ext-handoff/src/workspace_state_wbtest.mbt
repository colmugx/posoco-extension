///|
test "workspace_state/snapshot_is_detached" {
  let state = HandoffWorkspaceState(
    "/repo",
    branch=Some("main"),
    head=Some("abc123"),
    changes=[{ path: "src/a.mbt", status: "modified", }],
  )
  let snapshot = state.current()
  snapshot.changes.push({ path: "README.md", status: "modified", })
  let again = state.current()
  assert_eq(again.changes.length(), 1)
}

///|
test "workspace_state/replaces_branch_head_and_changes" {
  let state = HandoffWorkspaceState("/repo")
  state.set_branch(Some("feat/handoff"))
  state.set_head(Some("def456"))
  state.set_changes([
    { path: "src/handoff.mbt", status: "modified", },
    { path: "README.mbt.md", status: "modified", },
  ])
  let snapshot = state.current()
  assert_eq(snapshot.branch, Some("feat/handoff"))
  assert_eq(snapshot.head, Some("def456"))
  assert_eq(snapshot.changes.length(), 2)
}

///|
test "workspace_state/rejects_empty_root" {
  let state = HandoffWorkspaceState("")
  match state.snapshot("/repo") {
    Err(reason) => assert_true(reason.contains("root"))
    Ok(_) => fail("empty workspace root must be rejected")
  }
}
