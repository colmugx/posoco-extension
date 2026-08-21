///|
test "handoff_path/is_derived_from_workspace_root" {
  assert_eq(handoff_dir("/repo"), "/repo/.handoff")
  assert_eq(document_path("/repo"), "/repo/.handoff/HANDOFF.md")
}

///|
test "handoff_path/handles_root_with_trailing_slash" {
  assert_eq(handoff_dir("/repo/"), "/repo/.handoff")
  assert_eq(document_path("/repo/"), "/repo/.handoff/HANDOFF.md")
}
