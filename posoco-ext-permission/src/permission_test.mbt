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
/// Build a user text message for `before_model` transcript tests.
fn user_message(text : String) -> @kernel.Message {
  @kernel.Message::UserMessage(content=[@kernel.Content::Text(text)])
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
async test "rtk prefix is stripped: rtk moon and bare moon share one scope" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // rtk is a transparent project-local wrapper: `rtk moon check` scopes to
  // the underlying `moon`, so one approval covers both spellings (models
  // guided by AGENTS.md and hosts wiring posoco-ext-rtk both emit rtk).
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rtk moon check --target native"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  assert_true(
    policy.before_tool(test_call_cmd("bash", "moon test"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // A different underlying command is a different scope: asks again.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rtk git status"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 2)
  // A bare `rtk` carries no underlying command: keyless, asks every time.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rtk"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 3)
}

///|
async test "non-transparent shims keep shim + subcommand scope" {
  let source = ScriptedApproval::{ decision: AllowSession, asked: 0 }
  let policy = PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
    approval=Some(source as &ApprovalSource),
  )
  // sudo is not transparent: `sudo rm` keeps its own scope.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "sudo rm -rf /tmp/x"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  assert_true(
    policy.before_tool(test_call_cmd("bash", "sudo rm -rf /tmp/y"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
  // The rtk strip happens before shim refinement: `rtk sudo rm` scopes to
  // `sudo rm`, sharing the approval above — never to bare `rm`.
  assert_true(
    policy.before_tool(test_call_cmd("bash", "rtk sudo rm -rf /tmp/z"))
    is @posoco.ToolDecision::ApproveAfterConsent(_),
  )
  assert_eq(source.asked, 1)
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
test "permission policy contributes hook and command, no system prompt contributor" {
  let policy = PermissionPolicy::PermissionPolicy(Interactive)
  let manifest = policy.manifest()
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 0)
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
}

// ──────────────────────────────────────────────────────────────────────────
// Per-turn mode reminder (before_model)
// ──────────────────────────────────────────────────────────────────────────

///|
async test "before_model injects current mode reminder as user message" {
  let modes : Array[PermissionMode] = [
    ReadOnly,
    WorkspaceWrite,
    Interactive,
    Yolo,
  ]
  let expected_phrases : Array[String] = [
    "read-only", "workspace reads and writes", "interactive", "yolo",
  ]
  for i, mode in modes {
    let policy = PermissionPolicy::PermissionPolicy(mode)
    let messages = [user_message("hello")]
    let result = policy.before_model(messages)
    assert_eq(result.length(), 2)
    match result[1] {
      @kernel.Message::UserMessage(content~) =>
        match content {
          [@kernel.Content::Text(text)] => {
            assert_true(text.has_prefix("<permission-context"))
            assert_true(text.contains(expected_phrases[i]))
          }
          _ => fail("expected single text content")
        }
      _ => fail("expected user message")
    }
  }
}

///|
async test "before_model is idempotent" {
  let policy = PermissionPolicy::PermissionPolicy(ReadOnly)
  let messages = [user_message("hello")]
  let r1 = policy.before_model(messages)
  let r2 = policy.before_model(r1)
  assert_eq(r1.length(), 2)
  assert_eq(r2.length(), 2)
  assert_eq(r1[1], r2[1])
}

///|
async test "before_model replaces reminder in place when mode changes" {
  let policy = PermissionPolicy::PermissionPolicy(ReadOnly)
  let messages = [user_message("hello")]
  let r1 = policy.before_model(messages)
  assert_eq(r1.length(), 2)
  policy.mode = Yolo
  let r2 = policy.before_model(r1)
  assert_eq(r2.length(), 2)
  match r2[1] {
    @kernel.Message::UserMessage(content~) =>
      match content {
        [@kernel.Content::Text(text)] => {
          assert_true(text.contains("yolo"))
          assert_false(text.contains("read-only"))
        }
        _ => fail("expected single text content")
      }
    _ => fail("expected user message")
  }
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

// ──────────────────────────────────────────────────────────────────────────
// Exemption reports (bus topic `tool_exemptions`)
// ──────────────────────────────────────────────────────────────────────────

///|
async test "bus-reported tools bypass the gate in every mode" {
  let bus = @devkit.EventBus::EventBus()
  // Subscribe the gate BEFORE the reporting extension publishes — the bus
  // is fire-and-forget, a report with no subscriber is dropped.
  let policy = PermissionPolicy::PermissionPolicy(ReadOnly, bus=Some(bus))
  // Unknown tool, not yet reported: rejected in ReadOnly.
  assert_true(
    policy.before_tool(test_call("enter_plan_mode"))
    is @posoco.ToolDecision::Reject(_),
  )
  @devkit.publish_tool_exemptions(bus, source="posoco_ext_plan", tools=[
    "enter_plan_mode", "exit_plan_mode",
  ])
  // Reported: bypasses the gate even in ReadOnly...
  assert_true(
    policy.before_tool(test_call("enter_plan_mode"))
    is @posoco.ToolDecision::Approve(_),
  )
  assert_true(
    policy.before_tool(test_call("exit_plan_mode"))
    is @posoco.ToolDecision::Approve(_),
  )
  // ...while other unknown tools stay gated.
  assert_true(
    policy.before_tool(test_call("deploy")) is @posoco.ToolDecision::Reject(_),
  )
}

///|
async test "exempted tools never consult the approval source" {
  let source = ScriptedApproval::{ decision: AllowOnce, asked: 0 }
  let bus = @devkit.EventBus::EventBus()
  let policy = PermissionPolicy::PermissionPolicy(
    Interactive,
    approval=Some(source as &ApprovalSource),
    bus=Some(bus),
  )
  @devkit.publish_tool_exemptions(bus, source="posoco_ext_plan", tools=[
    "exit_plan_mode",
  ])
  assert_true(
    policy.before_tool(test_call("exit_plan_mode"))
    is @posoco.ToolDecision::Approve(_),
  )
  assert_eq(source.asked, 0)
  // Status surfaces the exemption set for code review.
  match @posoco.CommandPort::invoke(policy, "permission", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("exit_plan_mode"))
      let exempted : Array[Json] = match structured {
        Some(Object(fields)) =>
          match fields.get("exempted_tools") {
            Some(Array(entries)) => entries
            _ => []
          }
        _ => []
      }
      assert_true(
        exempted.contains(Json::string("posoco_ext_plan:exit_plan_mode")),
      )
    }
    _ => fail("expected /permission status to succeed")
  }
}

///|
async test "malformed exemption payloads are ignored" {
  let policy = PermissionPolicy::PermissionPolicy(ReadOnly)
  @devkit.BusSubscriber::on_bus_event(policy, {
    source: "rogue_ext",
    topic: @devkit.tool_exemptions_topic,
    data: Json::object({ "tools": Json::string("not-an-array") }),
  })
  assert_true(
    policy.before_tool(test_call("anything")) is @posoco.ToolDecision::Reject(_),
  )
}
