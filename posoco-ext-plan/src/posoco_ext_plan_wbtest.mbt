///|
/// Tests for posoco_ext_plan.

///|
fn plan_mode_with_reads() -> PlanMode {
  PlanMode(config=PlanModeConfig::{
    ..PlanModeConfig::default(),
    allowed_tools: ["read", "glob", "grep"],
  })
}

///|
fn tk_call(name : String) -> @posoco.ToolCall {
  tk_call_with_args(name, Json::null())
}

///|
fn tk_call_with_args(name : String, arguments : Json) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked(name),
    arguments,
  }
}

///|
fn bash_call(cmd : String) -> @posoco.ToolCall {
  tk_call_with_args("bash", Json::object({ "cmd": Json::string(cmd) }))
}

///|
fn write_call(tool : String, path : String) -> @posoco.ToolCall {
  tk_call_with_args(tool, Json::object({ "path": Json::string(path) }))
}

///|
async test "before_tool gates write tools by target while planning" {
  let plan = plan_mode_with_reads()
  plan.start()
  // Markdown under docs/ passes — research notes and draft docs are part
  // of planning.
  for
    target in [
      ("write", "docs/research/notes.md"),
      ("edit", "docs/plan-draft.md"),
      ("edit", "./docs/x.md"),
    ] {
    let (tool, path) = target
    match plan.before_tool(write_call(tool, path)) {
      @posoco.ToolDecision::Approve(..) => ()
      other => fail("expected Approve for '\{tool} \{path}', got \{other}")
    }
  }
  // Everything else is a precise target rejection: outside docs/, wrong
  // extension, or no target at all.
  for
    target in [
      ("write", "src/main.rs"),
      ("edit", "docs/build.sh"),
      ("write", "package.json"),
      ("apply_patch", "docs/styles.css"),
    ] {
    let (tool, path) = target
    match plan.before_tool(write_call(tool, path)) {
      @posoco.ToolDecision::Reject(reason~) => {
        assert_true(reason.contains("plan mode"))
        assert_true(reason.contains("docs/"))
      }
      other => fail("expected Reject for '\{tool} \{path}', got \{other}")
    }
  }
  match plan.before_tool(tk_call("write")) {
    @posoco.ToolDecision::Reject(..) => ()
    other => fail("expected Reject for write without path, got \{other}")
  }
}

///|
async test "before_tool target gate is off unless write tools are configured" {
  let plan = PlanMode(config=PlanModeConfig::{
    ..PlanModeConfig::default(),
    allowed_tools: ["read"],
    write_tools: [],
  })
  plan.start()
  match plan.before_tool(write_call("write", "docs/a.md")) {
    @posoco.ToolDecision::Reject(..) => ()
    other => fail("expected Reject with empty write_tools, got \{other}")
  }
}

///|
async test "before_tool admits read-only shell commands while planning" {
  let plan = plan_mode_with_reads()
  plan.start()
  // Read-only investigation commands pass through the shell gate.
  let read_only = [
    "ls -la", "find . -name '*.mbt' | head -20", "grep -rn 'plan' docs", "git status && git diff --stat",
    "git log --oneline -5",
  ]
  for cmd in read_only {
    match plan.before_tool(bash_call(cmd)) {
      @posoco.ToolDecision::Approve(..) => ()
      other => fail("expected Approve for '\{cmd}', got \{other}")
    }
  }
  // Mutating commands are rejected with read-only steering.
  for cmd in ["rm -rf build", "npm install", "git push", "cat a > b"] {
    match plan.before_tool(bash_call(cmd)) {
      @posoco.ToolDecision::Reject(reason~) => {
        assert_true(reason.contains("plan mode"))
        assert_true(reason.contains("read-only"))
      }
      other => fail("expected Reject for '\{cmd}', got \{other}")
    }
  }
  // No parseable `cmd` argument: conservative rejection.
  match plan.before_tool(tk_call("bash")) {
    @posoco.ToolDecision::Reject(..) => ()
    other => fail("expected Reject for bash without cmd, got \{other}")
  }
}

///|
async test "before_tool shell gate is off unless the name is configured" {
  let plan = PlanMode(config=PlanModeConfig::{
    ..PlanModeConfig::default(),
    allowed_tools: ["read"],
    shell_tools: [],
  })
  plan.start()
  match plan.before_tool(bash_call("ls -la")) {
    @posoco.ToolDecision::Reject(..) => ()
    other =>
      fail("expected Reject for bash with empty shell_tools, got \{other}")
  }
}

///|
async test "allowed_tools entries match by prefix with trailing *" {
  let plan = PlanMode(config=PlanModeConfig::{
    ..PlanModeConfig::default(),
    allowed_tools: ["read", "browser_*"],
  })
  plan.start()
  for name in ["read", "browser_snapshot", "browser_navigate", "browser_eval"] {
    match plan.before_tool(tk_call(name)) {
      @posoco.ToolDecision::Approve(..) => ()
      other => fail("expected Approve for '\{name}', got \{other}")
    }
  }
  for name in ["write", "browsermaker"] {
    match plan.before_tool(tk_call(name)) {
      @posoco.ToolDecision::Reject(..) => ()
      other => fail("expected Reject for '\{name}', got \{other}")
    }
  }
}

///|
test "state machine transitions" {
  let plan = plan_mode_with_reads()
  assert_eq(plan.status(), PlanStatus::Off)
  plan.start()
  assert_eq(plan.status(), PlanStatus::Planning)
  assert_true(plan.submit_plan("step 1: do the thing"))
  assert_eq(
    plan.status(),
    PlanStatus::ReadyForApproval(plan="step 1: do the thing"),
  )
  // reject → back to planning
  assert_true(plan.reject())
  assert_eq(plan.status(), PlanStatus::Planning)
  // resubmit + approve → off, plan returned
  assert_true(plan.submit_plan("step 1: revised"))
  assert_eq(plan.approve(), Some("step 1: revised"))
  assert_eq(plan.status(), PlanStatus::Off)
  // nothing pending: approve/reject/submit are no-ops
  assert_eq(plan.approve(), None)
  assert_false(plan.reject())
  assert_false(plan.submit_plan("ignored"))
  // stop is unconditional
  plan.start()
  plan.stop()
  assert_eq(plan.status(), PlanStatus::Off)
}

///|
async test "before_tool gates non-allowed tools while planning" {
  let plan = plan_mode_with_reads()
  // Off: everything passes through.
  match plan.before_tool(tk_call("write")) {
    @posoco.ToolDecision::Approve(..) => ()
    other => fail("expected Approve while Off, got \{other}")
  }
  plan.start()
  // Planning: allowed tools and the exit tool pass.
  for name in ["read", "glob", "grep", "exit_plan_mode"] {
    match plan.before_tool(tk_call(name)) {
      @posoco.ToolDecision::Approve(..) => ()
      other => fail("expected Approve for '\{name}', got \{other}")
    }
  }
  // Planning: write tools are rejected with guidance.
  match plan.before_tool(tk_call("write")) {
    @posoco.ToolDecision::Reject(reason~) =>
      assert_true(reason.contains("plan mode"))
    other => fail("expected Reject for 'write', got \{other}")
  }
  // ReadyForApproval still gates until the user approves.
  assert_true(plan.submit_plan("plan"))
  match plan.before_tool(tk_call("write")) {
    @posoco.ToolDecision::Reject(..) => ()
    other => fail("expected Reject while ReadyForApproval, got \{other}")
  }
  // After approval, everything passes again.
  ignore(plan.approve())
  match plan.before_tool(tk_call("write")) {
    @posoco.ToolDecision::Approve(..) => ()
    other => fail("expected Approve after approval, got \{other}")
  }
}

///|
test "system_prompt section only while planning" {
  let plan = plan_mode_with_reads()
  assert_eq(plan.system_prompt(), "")
  plan.start()
  let prompt = plan.system_prompt()
  assert_true(prompt.contains("PLAN MODE"))
  assert_true(prompt.contains("read, glob, grep"))
  assert_true(prompt.contains("exit_plan_mode"))
  assert_true(plan.submit_plan("plan"))
  assert_true(plan.system_prompt().contains("awaiting user approval"))
  plan.stop()
  assert_eq(plan.system_prompt(), "")
}

///|
async test "exit_plan_mode tool records the plan" {
  let plan = plan_mode_with_reads()
  plan.start()
  let outcome = plan.execute(
    "exit_plan_mode",
    tk_call_with_args(
      "exit_plan_mode",
      Json::object({ "plan": Json::string("1. read foo\n2. edit bar") }),
    ),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("submitted for user approval"))
    _ => fail("expected Success")
  }
  assert_eq(
    plan.status(),
    PlanStatus::ReadyForApproval(plan="1. read foo\n2. edit bar"),
  )
}

///|
async test "exit_plan_mode tool outside plan mode reports an error" {
  let plan = plan_mode_with_reads()
  let outcome = plan.execute(
    "exit_plan_mode",
    tk_call_with_args(
      "exit_plan_mode",
      Json::object({ "plan": Json::string("too early") }),
    ),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("not in plan mode"))
    other => fail("expected ToolReportedError, got \{other}")
  }
  assert_eq(plan.status(), PlanStatus::Off)
}

///|
async test "exit_plan_mode tool validates arguments" {
  let plan = plan_mode_with_reads()
  plan.start()
  try plan.execute("exit_plan_mode", tk_call("exit_plan_mode")) catch {
    @posoco.RuntimeError::InvocationFailed(message) =>
      assert_true(message.contains("arguments must be a JSON object"))
    other => fail("expected InvocationFailed, got \{other}")
  } noraise {
    _ => fail("expected InvocationFailed for non-object arguments")
  }
  // Unknown tool name raises UnknownTool.
  try plan.execute("other_tool", tk_call("other_tool")) catch {
    @posoco.RuntimeError::UnknownTool(message) =>
      assert_true(message.contains("unknown tool"))
    other => fail("expected UnknownTool, got \{other}")
  } noraise {
    _ => fail("expected UnknownTool for other_tool")
  }
}

///|
async test "list_tools declares the configured tools" {
  let plan = plan_mode_with_reads()
  // Without allow_model_entry, only the exit tool is advertised.
  let tools = plan.list_tools()
  assert_eq(tools.length(), 1)
  assert_eq(tools[0].name.to_string(), "exit_plan_mode")
  // With allow_model_entry, the enter tool is advertised too.
  let entering = PlanMode(config=PlanModeConfig::{
    ..PlanModeConfig::default(),
    allow_model_entry: true,
  })
  let entering_tools = entering.list_tools()
  assert_eq(entering_tools.length(), 2)
  assert_eq(entering_tools[1].name.to_string(), "enter_plan_mode")
}

///|
async test "bare /plan toggles plan mode" {
  let plan = plan_mode_with_reads()
  // toggle on
  match plan.invoke("plan", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("plan mode on"))
      assert_eq(
        structured,
        Some(
          Json::object({
            "status": Json::string("planning"),
            "plan": Json::null(),
            "allowed_tools": Json::array([
              Json::string("read"),
              Json::string("glob"),
              Json::string("grep"),
            ]),
          }),
        ),
      )
    }
    _ => fail("expected Success")
  }
  assert_eq(plan.status(), PlanStatus::Planning)
  // toggle off
  match plan.invoke("plan", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("plan mode off"))
    _ => fail("expected Success")
  }
  assert_eq(plan.status(), PlanStatus::Off)
}

///|
async test "plan command on/off/status" {
  let plan = plan_mode_with_reads()
  // status inspects without touching state
  match plan.invoke("plan", Json::string("status")) {
    @posoco.CommandOutcome::Success(structured~, ..) =>
      assert_eq(
        structured,
        Some(
          Json::object({
            "status": Json::string("off"),
            "plan": Json::null(),
            "allowed_tools": Json::array([
              Json::string("read"),
              Json::string("glob"),
              Json::string("grep"),
            ]),
          }),
        ),
      )
    _ => fail("expected Success")
  }
  assert_eq(plan.status(), PlanStatus::Off)
  // on → planning
  match plan.invoke("plan", Json::string("on")) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("plan mode on"))
    _ => fail("expected Success")
  }
  assert_eq(plan.status(), PlanStatus::Planning)
  // off → off
  match plan.invoke("plan", Json::object({ "action": Json::string("off") })) {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("expected Success")
  }
  assert_eq(plan.status(), PlanStatus::Off)
  // unknown action fails without touching state
  match plan.invoke("plan", Json::string("sideways")) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("unknown plan action"))
    _ => fail("expected Failure")
  }
}

///|
async test "enter_plan_mode tool enters without approval" {
  let plan = PlanMode(config=PlanModeConfig::{
    ..PlanModeConfig::default(),
    allow_model_entry: true,
  })
  // Off prompt advertises the enter tool.
  assert_true(plan.system_prompt().contains("enter_plan_mode"))
  let outcome = plan.execute("enter_plan_mode", tk_call("enter_plan_mode"))
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("Plan mode is now active"))
    other => fail("expected Success, got \{other}")
  }
  assert_eq(plan.status(), PlanStatus::Planning)
  // Idempotent while planning.
  match plan.execute("enter_plan_mode", tk_call("enter_plan_mode")) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("Already in plan mode"))
    other => fail("expected Success, got \{other}")
  }
  // Blocked once a plan is awaiting approval.
  assert_true(plan.submit_plan("plan"))
  match plan.execute("enter_plan_mode", tk_call("enter_plan_mode")) {
    @posoco.ToolOutcome::ToolReportedError(..) => ()
    other => fail("expected ToolReportedError, got \{other}")
  }
}

///|
async test "enter_plan_mode tool is rejected when model entry is disabled" {
  let plan = plan_mode_with_reads()
  try plan.execute("enter_plan_mode", tk_call("enter_plan_mode")) catch {
    @posoco.RuntimeError::UnknownTool(message) =>
      assert_true(message.contains("unknown tool"))
    other => fail("expected UnknownTool, got \{other}")
  } noraise {
    _ => fail("expected UnknownTool when allow_model_entry is false")
  }
  assert_eq(plan.status(), PlanStatus::Off)
}

///|
async test "plan.approve and plan.reject drive the approval flow" {
  let plan = plan_mode_with_reads()
  // nothing pending → Failure
  match plan.invoke("plan.approve", Json::null()) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("no plan"))
    _ => fail("expected Failure")
  }
  plan.start()
  assert_true(plan.submit_plan("the plan"))
  // reject → back to planning, feedback echoed
  match
    plan.invoke(
      "plan.reject",
      Json::object({ "feedback": Json::string("missing tests") }),
    ) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("missing tests"))
    _ => fail("expected Success")
  }
  assert_eq(plan.status(), PlanStatus::Planning)
  // approve → off
  assert_true(plan.submit_plan("the plan v2"))
  match plan.invoke("plan.approve", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("approved"))
    _ => fail("expected Success")
  }
  assert_eq(plan.status(), PlanStatus::Off)
}

///|
async test "unknown command id raises NotFound" {
  let plan = plan_mode_with_reads()
  try plan.invoke("nope", Json::null()) catch {
    @posoco.CommandError::NotFound(id) => assert_eq(id, "nope")
    other => fail("expected NotFound, got \{other}")
  } noraise {
    _ => fail("expected NotFound for unknown command id")
  }
}

///|
test "extension manifest wires all four port views" {
  let plan = plan_mode_with_reads()
  assert_eq(plan.extension_id(), "posoco_ext_plan")
  let manifest = plan.manifest()
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
  assert_eq(manifest.commands.length(), 1)
}

///|
/// ScriptedReview — records asks, returns a fixed verdict.
struct ScriptedReview {
  decision : PlanReviewDecision
  mut asked : Int
}

///|
impl PlanReviewSource for ScriptedReview with fn review(
  self,
  _request : PlanReviewRequest,
) -> PlanReviewDecision {
  self.asked = self.asked + 1
  self.decision
}

///|
fn exit_call(plan_text : String) -> @posoco.ToolCall {
  tk_call_with_args(
    "exit_plan_mode",
    Json::object({ "plan": Json::string(plan_text) }),
  )
}

///|
async test "review source accepts the plan in one action" {
  let review = ScriptedReview::{ decision: Accept, asked: 0 }
  let plan = PlanMode(
    config=PlanModeConfig::{
      ..PlanModeConfig::default(),
      allowed_tools: ["read"],
    },
    review=Some(review as &PlanReviewSource),
  )
  plan.start()
  let call = exit_call("1. do it")
  // before_tool runs the review and approves the exit call.
  match plan.before_tool(call) {
    @posoco.ToolDecision::Approve(..) => ()
    other => fail("expected Approve, got \{other}")
  }
  assert_eq(review.asked, 1)
  // Execution consumes the verdict: accepted + plan mode off.
  match plan.execute("exit_plan_mode", call) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("accepted"))
    other => fail("expected Success, got \{other}")
  }
  assert_eq(plan.status(), PlanStatus::Off)
}

///|
async test "review revise keeps planning and feeds the reason back" {
  let review = ScriptedReview::{
    decision: Revise(feedback="add tests"),
    asked: 0,
  }
  let plan = PlanMode(
    config=PlanModeConfig::{
      ..PlanModeConfig::default(),
      allowed_tools: ["read"],
    },
    review=Some(review as &PlanReviewSource),
  )
  plan.start()
  let call = exit_call("1. do it")
  match plan.before_tool(call) {
    @posoco.ToolDecision::Approve(..) => ()
    other => fail("expected Approve, got \{other}")
  }
  match plan.execute("exit_plan_mode", call) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("add tests"))
    other => fail("expected ToolReportedError, got \{other}")
  }
  assert_eq(plan.status(), PlanStatus::Planning)
}

///|
async test "review is only consulted while planning" {
  let review = ScriptedReview::{ decision: Accept, asked: 0 }
  let plan = PlanMode(review=Some(review as &PlanReviewSource))
  // Off: the exit call is approved but NOT reviewed; execution reports
  // not-in-plan-mode.
  let call = exit_call("too early")
  match plan.before_tool(call) {
    @posoco.ToolDecision::Approve(..) => ()
    other => fail("expected Approve, got \{other}")
  }
  assert_eq(review.asked, 0)
  match plan.execute("exit_plan_mode", call) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("not in plan mode"))
    other => fail("expected ToolReportedError, got \{other}")
  }
}

///|
async test "AutoAcceptReview is the unattended (yolo) posture" {
  let plan = PlanMode(review=Some(AutoAcceptReview::{  } as &PlanReviewSource))
  plan.start()
  let call = exit_call("1. unattended")
  match plan.before_tool(call) {
    @posoco.ToolDecision::Approve(..) => ()
    other => fail("expected Approve, got \{other}")
  }
  match plan.execute("exit_plan_mode", call) {
    @posoco.ToolOutcome::Success(..) => ()
    other => fail("expected Success, got \{other}")
  }
  assert_eq(plan.status(), PlanStatus::Off)
}
