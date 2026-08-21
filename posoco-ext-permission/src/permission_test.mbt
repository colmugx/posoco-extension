///|
fn test_call(name : String) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call-1"),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([])),
  }
}

///|
/// Scripted approval source: returns a fixed decision, records every ask.
struct ScriptedApproval {
  decision : ApprovalDecision
  mut asked : Int
}

///|
impl ApprovalSource for ScriptedApproval with fn ask(self, _request) {
  self.asked = self.asked + 1
  self.decision
}

// ──────────────────────────────────────────────────────────────────────────
// ReadOnly mode
// ──────────────────────────────────────────────────────────────────────────

///|
async test "read-only mode approves inspection and rejects mutation" {
  let policy = PermissionPolicy::new(ReadOnly)
  assert_true(
    policy.before_tool(test_call("read"))
    is @posoco.ToolHookDecision::Approve(_),
  )
  assert_true(
    policy.before_tool(test_call("edit")) is @posoco.ToolHookDecision::Reject(_),
  )
  assert_true(
    policy.before_tool(test_call("bash")) is @posoco.ToolHookDecision::Reject(_),
  )
}

// ──────────────────────────────────────────────────────────────────────────
// WorkspaceWrite mode
// ──────────────────────────────────────────────────────────────────────────

///|
async test "workspace-write without source denies shell and unknown" {
  let policy = PermissionPolicy::new(WorkspaceWrite)
  // write is not auto-approved in WorkspaceWrite (goes through gate); with no
  // source it is denied.
  assert_true(
    policy.before_tool(test_call("write"))
    is @posoco.ToolHookDecision::Reject(_),
  )
  assert_true(
    policy.before_tool(test_call("bash")) is @posoco.ToolHookDecision::Reject(_),
  )
  assert_true(
    policy.before_tool(test_call("mcp__deploy"))
    is @posoco.ToolHookDecision::Reject(_),
  )
}

///|
async test "workspace-write with source approves writes via gate, caches session" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::new(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // First write: asks the source.
  assert_true(
    policy.before_tool(test_call("write"))
    is @posoco.ToolHookDecision::Approve(_),
  )
  assert_eq(source.asked, 1)
  // Second write of the SAME tool: session cache hit, no re-ask.
  assert_true(
    policy.before_tool(test_call("write"))
    is @posoco.ToolHookDecision::Approve(_),
  )
  assert_eq(source.asked, 1)
}

///|
async test "workspace-write deny surfaces the reason" {
  let source = ScriptedApproval::{
    decision: Deny(reason="user said no"),
    asked: 0,
  }
  let policy = PermissionPolicy::new(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  match policy.before_tool(test_call("bash")) {
    @posoco.ToolHookDecision::Reject(reason~) =>
      assert_true(reason.contains("user said no"))
    _ => fail("expected bash to be rejected")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Interactive mode
// ──────────────────────────────────────────────────────────────────────────

///|
async test "interactive mode approves reads and gates side effects" {
  let source = ScriptedApproval::{ decision: AllowOnce, asked: 0 }
  let policy = PermissionPolicy::new(
    Interactive,
    approval=Some(source as &ApprovalSource),
  )
  // read: auto-approved, never asks.
  assert_true(
    policy.before_tool(test_call("grep"))
    is @posoco.ToolHookDecision::Approve(_),
  )
  assert_eq(source.asked, 0)
  // apply_patch: gated, AllowOnce does not cache.
  assert_true(
    policy.before_tool(test_call("apply_patch"))
    is @posoco.ToolHookDecision::Approve(_),
  )
  assert_eq(source.asked, 1)
  // Same tool again: AllowOnce did not cache, asks again.
  assert_true(
    policy.before_tool(test_call("apply_patch"))
    is @posoco.ToolHookDecision::Approve(_),
  )
  assert_eq(source.asked, 2)
}

// ──────────────────────────────────────────────────────────────────────────
// Manifest
// ──────────────────────────────────────────────────────────────────────────

///|
test "permission policy contributes hook and prompt" {
  let policy = PermissionPolicy::new(Interactive)
  let manifest = policy.manifest()
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
}
