///|
/// Tests for posoco_ext_plan.

///|
fn plan_mode_with_reads() -> PlanMode {
  PlanMode::new(config=PlanModeConfig::{
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
test "before_tool gates non-allowed tools while planning" {
  let plan = plan_mode_with_reads()
  // Off: everything passes through.
  match plan.before_tool(tk_call("write")) {
    @posoco.ToolHookDecision::Approve(..) => ()
    other => fail("expected Approve while Off, got \{other}")
  }
  plan.start()
  // Planning: allowed tools and the exit tool pass.
  for name in ["read", "glob", "grep", "exit_plan_mode"] {
    match plan.before_tool(tk_call(name)) {
      @posoco.ToolHookDecision::Approve(..) => ()
      other => fail("expected Approve for '\{name}', got \{other}")
    }
  }
  // Planning: write tools are rejected with guidance.
  match plan.before_tool(tk_call("write")) {
    @posoco.ToolHookDecision::Reject(reason~) =>
      assert_true(reason.contains("plan mode"))
    other => fail("expected Reject for 'write', got \{other}")
  }
  // ReadyForApproval still gates until the user approves.
  assert_true(plan.submit_plan("plan"))
  match plan.before_tool(tk_call("write")) {
    @posoco.ToolHookDecision::Reject(..) => ()
    other => fail("expected Reject while ReadyForApproval, got \{other}")
  }
  // After approval, everything passes again.
  ignore(plan.approve())
  match plan.before_tool(tk_call("write")) {
    @posoco.ToolHookDecision::Approve(..) => ()
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
  let entering = PlanMode::new(config=PlanModeConfig::{
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
  let plan = PlanMode::new(config=PlanModeConfig::{
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
