///|
fn test_call(name : String) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call-1"),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([])),
  }
}

///|
test "read-only mode approves inspection and rejects mutation" {
  let policy = PermissionPolicy::new(ReadOnly)
  assert_true(policy.before_tool(test_call("read")) is @posoco.ToolHookDecision::Approve(_))
  assert_true(policy.before_tool(test_call("edit")) is @posoco.ToolHookDecision::Reject(_))
  assert_true(policy.before_tool(test_call("bash")) is @posoco.ToolHookDecision::Reject(_))
}

///|
test "workspace-write mode defers shell and unknown tools" {
  let policy = PermissionPolicy::new(WorkspaceWrite)
  assert_true(policy.before_tool(test_call("write")) is @posoco.ToolHookDecision::Approve(_))
  assert_true(policy.before_tool(test_call("bash")) is @posoco.ToolHookDecision::Defer(_))
  assert_true(policy.before_tool(test_call("mcp__deploy")) is @posoco.ToolHookDecision::Defer(_))
}

///|
test "interactive mode approves reads and defers side effects" {
  let policy = PermissionPolicy::new(Interactive)
  assert_true(policy.before_tool(test_call("grep")) is @posoco.ToolHookDecision::Approve(_))
  assert_true(policy.before_tool(test_call("apply_patch")) is @posoco.ToolHookDecision::Defer(_))
}

///|
test "permission policy contributes hook and prompt" {
  let policy = PermissionPolicy::new(Interactive)
  let manifest = policy.manifest()
  assert_eq(manifest.pre_tool_hooks.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
}
