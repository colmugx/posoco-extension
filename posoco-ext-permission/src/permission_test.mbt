///|
fn test_call(name : String) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call-1"),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([])),
  }
}

///|
/// Call with a single `path` string argument, as write/edit tools carry.
fn test_call_path(name : String, path : String) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call-1"),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([("path", Json::string(path))])),
  }
}

///|
/// Call with a single `cmd` string argument, as the bash tool carries.
fn test_call_cmd(name : String, cmd : String) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call-1"),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([("cmd", Json::string(cmd))])),
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
  let policy = PermissionPolicy::PermissionPolicy(ReadOnly)
  assert_true(
    policy.before_tool(test_call("read")) is @posoco.ToolDecision::Approve(_),
  )
  assert_true(
    policy.before_tool(test_call("edit")) is @posoco.ToolDecision::Reject(_),
  )
  assert_true(
    policy.before_tool(test_call("bash")) is @posoco.ToolDecision::Reject(_),
  )
}

// ──────────────────────────────────────────────────────────────────────────
// WorkspaceWrite mode
// ──────────────────────────────────────────────────────────────────────────

///|
async test "workspace-write without source denies shell and unknown" {
  let policy = PermissionPolicy::PermissionPolicy(WorkspaceWrite)
  // write is not auto-approved in WorkspaceWrite (goes through gate); with no
  // source it is denied.
  assert_true(
    policy.before_tool(test_call("write")) is @posoco.ToolDecision::Reject(_),
  )
  assert_true(
    policy.before_tool(test_call("bash")) is @posoco.ToolDecision::Reject(_),
  )
  assert_true(
    policy.before_tool(test_call("mcp__deploy"))
    is @posoco.ToolDecision::Reject(_),
  )
}

///|
async test "workspace-write with source approves writes via gate, caches per tool" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // First write to src/a.txt: asks the source.
  assert_true(
    policy.before_tool(test_call_path("write", "src/a.txt"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // Same tool, same path: session cache hit, no re-ask.
  assert_true(
    policy.before_tool(test_call_path("write", "src/a.txt"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // Same tool, different path: the tool-name cache covers it — one approval
  // covers the tool for the session.
  assert_true(
    policy.before_tool(test_call_path("write", "src/b.txt"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
}

///|
async test "shell approvals are remembered per segment scope" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // Approving `npm run build` remembers the `npm` scope for the session...
  assert_true(
    policy.before_tool(test_call_cmd("bash", "npm run build"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // ...so a later `npm run test` is pre-approved...
  assert_true(
    policy.before_tool(test_call_cmd("bash", "npm run test"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // ...but `rm -rf` is a different scope and asks again — approving `npm`
  // must never approve `rm`.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rm -rf x"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 2)
  // A shell call without a parseable `cmd` has no cache scope: it asks every
  // time.
  assert_true(
    policy.before_tool(test_call("bash"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 3)
  assert_true(
    policy.before_tool(test_call("bash"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 4)
}

///|
async test "shim commands scope to shim + subcommand (rtk)" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // ext-rtk rewrites shell commands through `rtk`; approving
  // `rtk moon check` must scope to `rtk moon`, not bare `rtk`.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rtk moon check --target native"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // `rtk moon test` shares the `rtk moon` scope: pre-approved.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rtk moon test"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // `rtk git status` is a different scope: asks again.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rtk git status"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 2)
}

///|
async test "compound commands require every segment scope" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // Approve `cargo build && npm test`: both segment scopes (`cargo`,
  // `npm`) are remembered.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "cargo build && npm test"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // Same scopes, different shape: pre-approved.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "npm test && cargo build"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // A new segment scope inside a compound still asks: `cargo` is known but
  // `rm` is not.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "cargo build && rm -rf x"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 2)
}

///|
async test "write approval without a path is still cached per tool" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // Write-class approvals scope to the tool name — path or no path, the
  // second call is pre-approved.
  assert_true(
    policy.before_tool(test_call("write"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  assert_true(
    policy.before_tool(test_call("write"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
}

///|
async test "unknown tools are cached per tool name" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // An unknown (e.g. MCP) tool approved once is pre-approved for the
  // session; a different unknown tool still asks.
  assert_true(
    policy.before_tool(test_call("mcp__deploy"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  assert_true(
    policy.before_tool(test_call("mcp__deploy"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  assert_true(
    policy.before_tool(test_call("mcp__rollback"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 2)
}

///|
async test "workspace-write deny surfaces the reason" {
  let source = ScriptedApproval::{
    decision: Deny(reason="user said no"),
    asked: 0,
  }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  match policy.before_tool(test_call("bash")) {
    @posoco.ToolDecision::Reject(reason~) =>
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
  let policy = PermissionPolicy::PermissionPolicy(
    Interactive,
    approval=Some(source as &ApprovalSource),
  )
  // read: auto-approved, never asks.
  assert_true(
    policy.before_tool(test_call("grep")) is @posoco.ToolDecision::Approve(_),
  )
  assert_eq(source.asked, 0)
  // apply_patch: gated, AllowOnce does not cache.
  assert_true(
    policy.before_tool(test_call("apply_patch"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // Same tool again: AllowOnce did not cache, asks again.
  assert_true(
    policy.before_tool(test_call("apply_patch"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 2)
}

///|
async test "read-only shell commands are pre-approved in every mode" {
  let source = ScriptedApproval::{
    decision: Deny(reason="should not be asked"),
    asked: 0,
  }
  // Interactive: provably read-only commands never reach the source.
  let interactive = PermissionPolicy::PermissionPolicy(
    Interactive,
    approval=Some(source as &ApprovalSource),
  )
  assert_true(
    interactive.before_tool(test_call_cmd("bash", "ls -la"))
    is @posoco.ToolDecision::Approve(_),
  )
  assert_true(
    interactive.before_tool(test_call_cmd("bash", "git status && git diff"))
    is @posoco.ToolDecision::Approve(_),
  )
  assert_eq(source.asked, 0)
  // ReadOnly mode too: read-only shell IS inspection.
  let ro = PermissionPolicy::PermissionPolicy(ReadOnly)
  assert_true(
    ro.before_tool(test_call_cmd("bash", "grep -rn x src"))
    is @posoco.ToolDecision::Approve(_),
  )
  assert_true(
    ro.before_tool(test_call_cmd("bash", "rm -rf x"))
    is @posoco.ToolDecision::Reject(_),
  )
  // Opaque commands still go through the approval gate — the fast path
  // never widens what arbitrary scripts may do.
  let allow_source = ScriptedApproval::{ decision: AllowOnce, asked: 0 }
  let ww = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(allow_source as &ApprovalSource),
  )
  assert_true(
    ww.before_tool(test_call_cmd("bash", "ego-browser nodejs --inspect"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(allow_source.asked, 1)
}

// ──────────────────────────────────────────────────────────────────────────
// Manifest
// ──────────────────────────────────────────────────────────────────────────

///|
test "permission policy contributes hook, prompt, and command" {
  let policy = PermissionPolicy::PermissionPolicy(Interactive)
  let manifest = policy.manifest()
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
  assert_eq(manifest.commands.length(), 1)
}

///|
async test "ask_question is pre-approved in every mode: asking to ask is noise" {
  // Interactive: approved without consulting the approval source.
  let source = ScriptedApproval::{
    decision: Deny(reason="should not be asked"),
    asked: 0,
  }
  let interactive = PermissionPolicy::PermissionPolicy(
    Interactive,
    approval=Some(source as &ApprovalSource),
  )
  let question : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked("ask_question"),
    arguments: Json::object(
      Map::from_array([
        ("question", Json::string("Ship on Friday?")),
        ("type", Json::string("confirm")),
      ]),
    ),
  }
  assert_true(
    interactive.before_tool(question) is @posoco.ToolDecision::Approve(_),
  )
  assert_eq(source.asked, 0)
  // ReadOnly allows it too: talking to the user is not a side effect.
  let ro_policy = PermissionPolicy::PermissionPolicy(ReadOnly)
  assert_true(
    ro_policy.before_tool(question) is @posoco.ToolDecision::Approve(_),
  )
}

// ──────────────────────────────────────────────────────────────────────────
// Skill tools
// ──────────────────────────────────────────────────────────────────────────

///|
async test "skill activation tools are pre-approved like reads" {
  let source = ScriptedApproval::{
    decision: Deny(reason="should not be asked"),
    asked: 0,
  }
  let policy = PermissionPolicy::PermissionPolicy(
    Interactive,
    approval=Some(source as &ApprovalSource),
  )
  assert_true(
    policy.before_tool(test_call("activate_skill"))
    is @posoco.ToolDecision::Approve(_),
  )
  assert_true(
    policy.before_tool(test_call("read_skill_resource"))
    is @posoco.ToolDecision::Approve(_),
  )
  assert_eq(source.asked, 0)
  // ReadOnly allows them too: loading instructions mutates nothing.
  let ro_policy = PermissionPolicy::PermissionPolicy(ReadOnly)
  assert_true(
    ro_policy.before_tool(test_call("activate_skill"))
    is @posoco.ToolDecision::Approve(_),
  )
}

// ──────────────────────────────────────────────────────────────────────────
// Yolo mode
// ──────────────────────────────────────────────────────────────────────────

///|
async test "yolo mode pre-approves every tool without a source" {
  let policy = PermissionPolicy::PermissionPolicy(Yolo)
  for name in ["read", "write", "bash", "mcp__deploy"] {
    assert_true(
      policy.before_tool(test_call(name)) is @posoco.ToolDecision::Approve(_),
    )
  }
  assert_true(policy.system_prompt().contains("yolo"))
}

// ──────────────────────────────────────────────────────────────────────────
// /permission command
// ──────────────────────────────────────────────────────────────────────────

///|
async test "/permission reports status, switches mode, resets approvals" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // Bare invocation reports the current mode.
  match @posoco.CommandPort::invoke(policy, "permission", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("workspace_write"))
    _ => fail("expected /permission status to succeed")
  }
  // Populate one session approval, see it in status, then reset it.
  ignore(policy.before_tool(test_call_cmd("bash", "npm install")))
  match
    @posoco.CommandPort::invoke(
      policy,
      "permission",
      Json::object(Map::from_array([("action", Json::string("status"))])),
    ) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("bash:npm"))
    _ => fail("expected /permission status to succeed")
  }
  match
    @posoco.CommandPort::invoke(
      policy,
      "permission",
      Json::object(Map::from_array([("action", Json::string("reset"))])),
    ) {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("expected /permission reset to succeed")
  }
  // After reset the `npm` scope is forgotten: the same call asks again.
  ignore(policy.before_tool(test_call_cmd("bash", "npm install")))
  assert_eq(source.asked, 2)
  // Mode switch via the declared param, a bare string, and `_positional`.
  match
    @posoco.CommandPort::invoke(
      policy,
      "permission",
      Json::object(Map::from_array([("action", Json::string("yolo"))])),
    ) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("yolo"))
    _ => fail("expected /permission yolo to succeed")
  }
  // Yolo now pre-approves without touching the source.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rm -rf x"))
    is @posoco.ToolDecision::Approve(_),
  )
  assert_eq(source.asked, 2)
  match
    @posoco.CommandPort::invoke(
      policy,
      "permission",
      Json::string("interactive"),
    ) {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("expected bare-string mode switch to succeed")
  }
  match
    @posoco.CommandPort::invoke(
      policy,
      "permission",
      Json::object(Map::from_array([("_positional", Json::string("readonly"))])),
    ) {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("expected _positional mode switch to succeed")
  }
  // ReadOnly now rejects mutating bash without asking the source (`ls`
  // would take the read-only fast path).
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rm -rf x"))
    is @posoco.ToolDecision::Reject(_),
  )
  assert_eq(source.asked, 2)
  // Unknown action fails; unknown command id raises NotFound.
  match
    @posoco.CommandPort::invoke(
      policy,
      "permission",
      Json::object(Map::from_array([("action", Json::string("bogus"))])),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("bogus"))
    _ => fail("expected /permission bogus to fail")
  }
  try @posoco.CommandPort::invoke(policy, "nope", Json::null()) catch {
    @posoco.CommandError::NotFound(id) => assert_eq(id, "nope")
    other => fail("expected NotFound, got \{other}")
  } noraise {
    _ => fail("expected NotFound for unknown command id")
  }
}
