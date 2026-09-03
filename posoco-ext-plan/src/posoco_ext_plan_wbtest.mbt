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
fn user_msg(text : String) -> @kernel.Message {
  @kernel.UserMessage(content=[@kernel.Text(text)])
}

///|
fn text_of(msg : @kernel.Message) -> String? {
  match msg {
    @kernel.UserMessage(content~) =>
      match content {
        [@kernel.Text(text)] => Some(text)
        _ => None
      }
    _ => None
  }
}

///|
fn plan_reminder_count(messages : Array[@kernel.Message]) -> Int {
  let mut count = 0
  for msg in messages {
    match text_of(msg) {
      Some(text) => if text.has_prefix("<plan-context") { count = count + 1 }
      None => ()
    }
  }
  count
}

///|
async test "before_tool gates write tools by target while planning" {
  let plan = plan_mode_with_reads()
  plan.start()
  // Markdown passes anywhere in the workspace — research notes and draft
  // plans are part of planning.
  for
    target in [
      ("write", "docs/research/notes.md"),
      ("edit", "src/scratch/plan-draft.md"),
      ("edit", "./x.md"),
      ("apply_patch", "PLAN.md"),
    ] {
    let (tool, path) = target
    match plan.before_tool(write_call(tool, path)) {
      @posoco.ToolDecision::Approve(..) => ()
      other => fail("expected Approve for '\{tool} \{path}', got \{other}")
    }
  }
  // Every non-Markdown target is a precise rejection: wrong extension or no
  // target at all.
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
        assert_true(reason.contains(".md"))
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
async test "before_model injects planning reminder at the end" {
  let plan = plan_mode_with_reads()
  plan.start()
  let messages : Array[@kernel.Message] = [user_msg("hello")]
  let result = plan.before_model(messages)
  assert_eq(result.length(), 2)
  let reminder = text_of(result[1]).unwrap()
  assert_true(reminder.has_prefix("<plan-context"))
  assert_true(reminder.contains("PLAN MODE"))
  assert_true(reminder.contains("read, glob, grep"))
  assert_true(reminder.contains("exit_plan_mode"))
}

///|
async test "before_model is idempotent when the reminder is already present" {
  let plan = plan_mode_with_reads()
  plan.start()
  let messages : Array[@kernel.Message] = [user_msg("hello")]
  let first = plan.before_model(messages)
  let second = plan.before_model(first)
  assert_eq(second.length(), 2)
  assert_eq(plan_reminder_count(second), 1)
  assert_eq(text_of(second[1]), text_of(first[1]))
}

///|
async test "before_model replaces the reminder in place on mode switch" {
  let plan = plan_mode_with_reads()
  plan.start()
  let messages = plan.before_model([user_msg("hello")])
  assert_true(plan.submit_plan("the plan"))
  let switched = plan.before_model(messages)
  assert_eq(switched.length(), 2)
  assert_eq(plan_reminder_count(switched), 1)
  let reminder = text_of(switched[1]).unwrap()
  assert_true(reminder.contains("awaiting user approval"))
  assert_false(reminder.contains("Investigate freely"))
}

///|
async test "before_model appends a one-time exit reminder when leaving plan mode" {
  let plan = plan_mode_with_reads()
  plan.start()
  let messages = plan.before_model([user_msg("hello")])
  assert_eq(plan_reminder_count(messages), 1)
  plan.stop()
  let exited = plan.before_model(messages)
  assert_eq(exited.length(), 3)
  assert_eq(plan_reminder_count(exited), 2)
  let exit_text = text_of(exited[2]).unwrap()
  assert_true(exit_text.contains("Plan mode has been exited"))
  // Subsequent Off turns do not add more reminders.
  let again = plan.before_model(exited)
  assert_eq(again.length(), 3)
  assert_eq(plan_reminder_count(again), 2)
}

///|
async test "before_model does nothing while Off" {
  let plan = plan_mode_with_reads()
  let messages : Array[@kernel.Message] = [user_msg("hello")]
  let result = plan.before_model(messages)
  assert_eq(result.length(), 1)
  assert_eq(plan_reminder_count(result), 0)
}

///|
async test "exit_plan_mode tool records the plan" {
  let plan = plan_mode_with_reads()
  plan.start()
  let outcome = plan.execute(
    "exit_plan_mode",
    tk_call_with_args(
      "exit_plan_mode",
      Json::object({
        "name": Json::string("read then edit"),
        "plan": Json::string("1. read foo\n2. edit bar"),
      }),
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
      Json::object({
        "name": Json::string("too early"),
        "plan": Json::string("too early"),
      }),
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
  // The enter tool is advertised through ToolProvider, not system prompt.
  let tools = plan.list_tools()
  assert_eq(tools.length(), 2)
  assert_eq(tools[1].name.to_string(), "enter_plan_mode")
  assert_true(tools[1].description.contains("read-only investigation"))
  assert_true(
    tools[1].description.contains("Markdown files anywhere in the workspace"),
  )
  let outcome = plan.execute("enter_plan_mode", tk_call("enter_plan_mode"))
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_true(content.contains("Plan mode is now active"))
      assert_true(content.contains("traceable"))
    }
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
test "extension manifest wires the three port views" {
  let plan = plan_mode_with_reads()
  assert_eq(plan.extension_id(), "posoco_ext_plan")
  let manifest = plan.manifest()
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.hooks.length(), 1)
  // Plan-mode discovery is through the advertised tool description and the
  // per-turn `before_model` reminder; no static system-prompt advertisement.
  assert_eq(manifest.prompt_contributors.length(), 0)
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
/// FailingReview — simulates a host review surface that errors out.
struct FailingReview {
  mut asked : Int
}

///|
suberror ReviewUnavailable {
  ReviewUnavailable(String)
}

///|
impl PlanReviewSource for FailingReview with fn review(
  self,
  _request : PlanReviewRequest,
) -> PlanReviewDecision raise {
  self.asked = self.asked + 1
  raise ReviewUnavailable::ReviewUnavailable("surface disconnected")
}

///|
fn exit_call(plan_text : String) -> @posoco.ToolCall {
  tk_call_with_args(
    "exit_plan_mode",
    Json::object({
      "name": Json::string("test plan"),
      "plan": Json::string(plan_text),
    }),
  )
}

///|
async test "review source accepts the plan in one action" {
  let review = ScriptedReview::{ decision: Accept, asked: 0, }
  let plan = PlanMode(
    config=PlanModeConfig::{
      ..PlanModeConfig::default(),
      allowed_tools: ["read"],
    },
    review=Some(review as &PlanReviewSource),
  )
  plan.start()
  let call = exit_call("1. do it")
  // before_tool is a pure gate: it approves the exit call without
  // consulting the review.
  match plan.before_tool(call) {
    @posoco.ToolDecision::Approve(..) => ()
    other => fail("expected Approve, got \{other}")
  }
  assert_eq(review.asked, 0)
  // The review runs inside the execution: accepted + plan mode off.
  match plan.execute("exit_plan_mode", call) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("accepted"))
    other => fail("expected Success, got \{other}")
  }
  assert_eq(review.asked, 1)
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
  let review = ScriptedReview::{ decision: Accept, asked: 0, }
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
  let plan = PlanMode(review=Some(AutoAcceptReview::{ } as &PlanReviewSource))
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

///|
async test "a failing review keeps planning with a retryable tool error" {
  let review = FailingReview::{ asked: 0, }
  let plan = PlanMode(
    config=PlanModeConfig::{
      ..PlanModeConfig::default(),
      allowed_tools: ["read"],
    },
    review=Some(review as &PlanReviewSource),
  )
  plan.start()
  match plan.execute("exit_plan_mode", exit_call("1. do it")) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      // Error::to_string only carries the constructor path, so the tool
      // result names the failure generically; the host logs the detail.
      assert_true(content.contains("plan review failed"))
    other => fail("expected ToolReportedError, got \{other}")
  }
  assert_eq(review.asked, 1)
  // The turn survives: still planning, the model may resubmit.
  assert_eq(plan.status(), PlanStatus::Planning)
}

///|
/// RecordingGate — captures bus events for exemption-report tests.
struct RecordingGate {
  events : Array[@devkit.BusEvent]
}

///|
impl @devkit.BusSubscriber for RecordingGate with fn on_bus_event(
  self : RecordingGate,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
async test "constructor reports the enter/exit tools on the bus" {
  let bus = @devkit.EventBus::EventBus()
  let gate = RecordingGate::{ events: [], }
  bus.subscribe(gate as &@devkit.BusSubscriber)
  ignore(
    PlanMode(
      config=PlanModeConfig::{
        ..PlanModeConfig::default(),
        allow_model_entry: true,
      },
      bus=Some(bus),
    ),
  )
  assert_eq(gate.events.length(), 1)
  assert_eq(gate.events[0].source, "posoco_ext_plan")
  assert_eq(gate.events[0].topic, @devkit.tool_exemptions_topic)
  assert_eq(
    @devkit.parse_tool_exemptions(gate.events[0].data),
    Some(["exit_plan_mode", "enter_plan_mode"]),
  )
}

///|
async test "without model entry only the exit tool is reported" {
  let bus = @devkit.EventBus::EventBus()
  let gate = RecordingGate::{ events: [], }
  bus.subscribe(gate as &@devkit.BusSubscriber)
  ignore(PlanMode(bus=Some(bus)))
  assert_eq(gate.events.length(), 1)
  assert_eq(
    @devkit.parse_tool_exemptions(gate.events[0].data),
    Some(["exit_plan_mode"]),
  )
}

///|
async test "plan.reject without a reason fails" {
  let plan = plan_mode_with_reads()
  plan.start()
  assert_true(plan.submit_plan("the plan"))
  for
    args in [Json::null(), Json::string(""), Json::object(Map::from_array([]))] {
    match plan.invoke("plan.reject", args) {
      @posoco.CommandOutcome::Failure(reason~) =>
        assert_true(reason.contains("needs a reason"))
      _ => fail("expected Failure for reject without feedback")
    }
  }
  // State untouched: still awaiting approval.
  assert_eq(plan.status(), PlanStatus::ReadyForApproval(plan="the plan"))
}

///|
async test "plan.dismiss discards the pending plan and exits" {
  let plan = plan_mode_with_reads()
  match plan.invoke("plan.dismiss", Json::null()) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("no plan"))
    _ => fail("expected Failure with nothing pending")
  }
  plan.start()
  assert_true(plan.submit_plan("the plan"))
  match plan.invoke("plan.dismiss", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("dismissed"))
    _ => fail("expected Success")
  }
  assert_eq(plan.status(), PlanStatus::Off)
}

///|
async test "review dismiss cancels the plan and instructs the model to stop" {
  let review = ScriptedReview::{ decision: Dismiss, asked: 0, }
  let plan = PlanMode(
    config=PlanModeConfig::{
      ..PlanModeConfig::default(),
      allowed_tools: ["read"],
    },
    review=Some(review as &PlanReviewSource),
  )
  plan.start()
  match plan.execute("exit_plan_mode", exit_call("1. do it")) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("dismissed"))
      assert_true(content.contains("no further tool calls"))
    }
    other => fail("expected ToolReportedError, got \{other}")
  }
  assert_eq(plan.status(), PlanStatus::Off)
}

///|
async test "completed plans are echoed once in the tool result" {
  let plan = plan_mode_with_reads()
  plan.start()
  match
    plan.execute("exit_plan_mode", exit_call("1. first step\n2. second step")) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("1. first step\n2. second step"))
    other => fail("expected Success, got \{other}")
  }
}

///|
async test "plan transitions publish status facts on the bus" {
  let bus = @devkit.EventBus::EventBus()
  let gate = RecordingGate::{ events: [], }
  bus.subscribe(gate as &@devkit.BusSubscriber)
  let plan = PlanMode(
    config=PlanModeConfig::{
      ..PlanModeConfig::default(),
      allowed_tools: ["read"],
    },
    bus=Some(bus),
  )
  // The exemption report is the first event; status ops follow the devkit
  // protocol on the status topic: segment "plan" (priority 10, value
  // "Plan") while active, unregister once off.
  plan.start()
  assert_true(plan.submit_plan("p"))
  ignore(plan.approve())
  plan.start()
  plan.stop()
  plan.start()
  assert_true(plan.submit_plan("p2"))
  match plan.invoke("plan.dismiss", Json::null()) {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("expected Success")
  }
  let ops : Array[@devkit.StatusOp] = gate.events
    .iter()
    .filter_map(fn(event) { @devkit.decode_status_op(event) })
    .collect()
  let registered = @devkit.Register(
    segment="plan",
    label=None,
    priority=10,
    value=Some("Plan"),
    color=Some("accent"),
  )
  assert_eq(ops.length(), 8)
  assert_eq(ops[0], registered)
  assert_eq(ops[1], registered)
  assert_eq(ops[2], @devkit.Unregister(segment="plan"))
  assert_eq(ops[3], registered)
  assert_eq(ops[4], @devkit.Unregister(segment="plan"))
  assert_eq(ops[5], registered)
  assert_eq(ops[6], registered)
  assert_eq(ops[7], @devkit.Unregister(segment="plan"))
}

// ──────────────────────────────────────────────────────────────────────────
// Plan-file persistence
// ──────────────────────────────────────────────────────────────────────────

///|
/// MemoryFs — in-memory WorkspaceFs fake for persistence tests.
struct MemoryFs {
  files : Map[String, String]
  dirs : Set[String]
}

///|
fn MemoryFs::MemoryFs() -> MemoryFs {
  { files: Map::from_array([]), dirs: Set([]), }
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn exists(self, path : String) -> Bool raise @workspace.WorkspaceFsError {
  self.files.contains(path) || self.dirs.contains(path)
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn kind(
  self,
  path : String,
  follow_symlink~ : Bool,
) -> @workspace.WorkspaceFileKind raise @workspace.WorkspaceFsError {
  ignore(follow_symlink)
  if self.files.contains(path) {
    @workspace.WorkspaceFileKind::File
  } else if self.dirs.contains(path) {
    @workspace.WorkspaceFileKind::Dir
  } else {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("missing \{path}")
  }
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn read_file(self, path : String) -> String raise @workspace.WorkspaceFsError {
  match self.files.get(path) {
    Some(content) => content
    None =>
      raise @workspace.WorkspaceFsError::WorkspaceFsError("missing \{path}")
  }
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn write_file(
  self,
  path : String,
  content : String,
) -> Unit raise @workspace.WorkspaceFsError {
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn write_file_atomic(
  self,
  path : String,
  content : String,
) -> Unit raise @workspace.WorkspaceFsError {
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn remove(self, path : String) -> Unit raise @workspace.WorkspaceFsError {
  ignore(self.files.remove(path))
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn rename(
  self,
  from : String,
  to_ : String,
  replace~ : Bool,
) -> Unit raise @workspace.WorkspaceFsError {
  ignore(replace)
  match self.files.get(from) {
    Some(content) => {
      ignore(self.files.remove(from))
      self.files[to_] = content
    }
    None =>
      raise @workspace.WorkspaceFsError::WorkspaceFsError("missing \{from}")
  }
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn realpath(_self, path : String) -> String raise @workspace.WorkspaceFsError {
  path
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn readdir(
  _self,
  _path : String,
  include_hidden~ : Bool,
) -> Array[String] raise @workspace.WorkspaceFsError {
  ignore(include_hidden)
  []
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn walk(
  _self,
  _root : String,
  _callback : async (String, Array[String]) -> Unit,
) -> Unit raise @workspace.WorkspaceFsError {
  ()
}

///|
impl @workspace.WorkspaceFs for MemoryFs with fn mkdir(
  self,
  path : String,
  recursive~ : Bool,
) -> Unit raise @workspace.WorkspaceFsError {
  ignore(recursive)
  self.dirs.add(path)
}

///|
fn planning_assistant_message(text : String) -> @kernel.Message {
  @kernel.Message::AssistantMessage(
    content=[@kernel.Content::Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@kernel.FinishReason::Stop,
  )
}

///|
async test "planning narrative accumulates into the session draft file" {
  let fs = MemoryFs::MemoryFs()
  let plan = PlanMode(
    config=PlanModeConfig::{
      ..PlanModeConfig::default(),
      allowed_tools: ["read"],
    },
    fs=Some(fs as &@workspace.WorkspaceFs),
    session_name="cetas-1",
  )
  plan.start()
  let messages : Array[@kernel.Message] = [
    planning_assistant_message("Reading the module layout."),
    planning_assistant_message("Found the seam in hooks.mbt."),
  ]
  ignore(plan.before_model(messages))
  let draft = @workspace.WorkspaceFs::read_file(fs, ".cetas/plan/cetas-1.md")
  assert_true(draft.contains("Reading the module layout."))
  assert_true(draft.contains("Found the seam in hooks.mbt."))
}

///|
async test "exit saves the named plan file and removes the draft" {
  let fs = MemoryFs::MemoryFs()
  let plan = PlanMode(
    config=PlanModeConfig::{
      ..PlanModeConfig::default(),
      allowed_tools: ["read"],
    },
    fs=Some(fs as &@workspace.WorkspaceFs),
    session_name="cetas-1",
  )
  plan.start()
  ignore(plan.before_model([planning_assistant_message("investigation notes")]))
  match
    plan.execute(
      "exit_plan_mode",
      tk_call_with_args(
        "exit_plan_mode",
        Json::object({
          "name": Json::string("Fix: the/bug v2"),
          "plan": Json::string("1. step"),
        }),
      ),
    ) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(
        content.contains("Saved to .cetas/plan/Fix-the-bug-v2_cetas-1.md"),
      )
    _ => fail("expected Success")
  }
  // Final file carries the header and plan; the draft is gone.
  let saved = @workspace.WorkspaceFs::read_file(
    fs, ".cetas/plan/Fix-the-bug-v2_cetas-1.md",
  )
  assert_true(saved.contains("# Fix: the/bug v2"))
  assert_true(saved.contains("1. step"))
  assert_false(@workspace.WorkspaceFs::exists(fs, ".cetas/plan/cetas-1.md"))
}

///|
async test "without a filesystem persistence is skipped silently" {
  let plan = plan_mode_with_reads()
  plan.start()
  match plan.execute("exit_plan_mode", exit_call("1. step")) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_false(content.contains("Saved to"))
    _ => fail("expected Success")
  }
}

///|
async test "exit rejects an empty or missing plan name" {
  let plan = plan_mode_with_reads()
  plan.start()
  for
    args in [
      Json::object(Map::from_array([("plan", Json::string("p"))])),
      Json::object({ "name": Json::string("  "), "plan": Json::string("p") }),
      Json::object({ "name": Json::number(1), "plan": Json::string("p") }),
    ] {
    try
      plan.execute("exit_plan_mode", tk_call_with_args("exit_plan_mode", args))
    catch {
      @posoco.RuntimeError::InvocationFailed(message) =>
        assert_true(message.contains("name"))
      _ => fail("expected InvocationFailed about name")
    } noraise {
      _ => fail("expected InvocationFailed about name")
    }
  }
  assert_eq(plan.status(), PlanStatus::Planning)
}
