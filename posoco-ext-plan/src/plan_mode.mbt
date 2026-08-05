///|
/// posoco_ext_plan — Plan mode extension for Posoco.
///
/// Plan mode constrains the agent to read-only tools while it investigates
/// and produces a plan. The model signals "plan ready" through the
/// `exit_plan_mode` tool; the product (cetas) then approves or rejects the
/// plan through the `plan.approve` / `plan.reject` commands. Only public
/// Posoco ports are used; approval UI stays on the product side.
///
/// Usage:
///   let plan = PlanMode::new(config=PlanModeConfig::{
///     ..PlanModeConfig::default(),
///     allowed_tools: ["read", "glob", "grep"],
///   })
///   let agent = Agent(exts=[plan], config=...)

///|
/// Plan mode state machine.
///
/// - `Off`: all hooks pass through; no prompt section is injected.
/// - `Planning`: non-allowed tools are rejected; the plan prompt is injected.
/// - `ReadyForApproval`: the model called `exit_plan_mode`; still gated until
///   the product approves (→ `Off`) or rejects (→ `Planning`).
pub(all) enum PlanStatus {
  Off
  Planning
  ReadyForApproval(plan~ : String)
} derive(Eq, Debug)

///|
pub impl Show for PlanStatus with fn to_string(self : PlanStatus) -> String {
  match self {
    Off => "Off"
    Planning => "Planning"
    ReadyForApproval(plan~) => "ReadyForApproval(plan=\{plan})"
  }
}

///|
/// Plan mode configuration.
pub(all) struct PlanModeConfig {
  /// Tools that remain executable while planning (read-only tools such as
  /// `read` / `glob` / `grep`). Empty = every tool except the enter/exit
  /// tools is rejected while plan mode is active.
  allowed_tools : Array[String]
  /// Name of the tool the model calls to submit a plan for approval.
  exit_tool_name : String
  /// Whether the model may enter plan mode on its own through the
  /// `enter_tool_name` tool. Entry never needs user approval; only exiting
  /// (via `plan.approve`) does.
  allow_model_entry : Bool
  /// Name of the tool the model calls to enter plan mode. Only advertised
  /// when `allow_model_entry` is true.
  enter_tool_name : String
} derive(Eq, Debug)

///|
/// Default configuration: no allowed tools, exit tool named `exit_plan_mode`,
/// model-initiated entry disabled.
pub fn PlanModeConfig::default() -> PlanModeConfig {
  {
    allowed_tools: [],
    exit_tool_name: "exit_plan_mode",
    allow_model_entry: false,
    enter_tool_name: "enter_plan_mode",
  }
}

///|
/// Central struct: implements Hook + SystemPromptContributor +
/// ToolProvider + CommandPort + Extension on one shared state.
///
/// Pass the same instance to the agent composer once; every port view sees
/// the same mutable status.
pub(all) struct PlanMode {
  config : PlanModeConfig
  mut status : PlanStatus
}

///|
/// Create a PlanMode with the given configuration, starting `Off`.
///
/// # Example
/// ```mbt check
/// test "plan mode gates write tools until the plan is approved" {
///   let plan = PlanMode::new(config=PlanModeConfig::{
///     ..PlanModeConfig::default(),
///     allowed_tools: ["read", "glob", "grep"],
///   })
///   plan.start()
///   let call : @posoco.ToolCall = @posoco.ToolCall::{
///     call_id: @posoco.CallId::unchecked("c1"),
///     name: @posoco.ToolName::unchecked("write"),
///     arguments: Json::null(),
///   }
///   match plan.before_tool(call) {
///     @posoco.ToolHookDecision::Reject(reason~) =>
///       assert_true(reason.contains("plan mode"))
///     _ => fail("write must be rejected while planning")
///   }
///   let read_call : @posoco.ToolCall = @posoco.ToolCall::{
///     call_id: @posoco.CallId::unchecked("c2"),
///     name: @posoco.ToolName::unchecked("read"),
///     arguments: Json::null(),
///   }
///   match plan.before_tool(read_call) {
///     @posoco.ToolHookDecision::Approve(..) => ()
///     _ => fail("read must stay available while planning")
///   }
/// }
/// ```
pub fn PlanMode::new(
  config? : PlanModeConfig = PlanModeConfig::default(),
) -> PlanMode {
  { config, status: Off }
}

///|
/// Current plan mode status.
pub fn PlanMode::status(self : PlanMode) -> PlanStatus {
  self.status
}

///|
/// Enter plan mode. Idempotent: re-entering restarts planning and drops any
/// plan awaiting approval.
pub fn PlanMode::start(self : PlanMode) -> Unit {
  self.status = Planning
}

///|
/// Leave plan mode unconditionally, discarding any pending plan.
pub fn PlanMode::stop(self : PlanMode) -> Unit {
  self.status = Off
}

///|
/// Toggle plan mode: Off → Planning, anything else → Off. Backs the bare
/// `/plan` command and the Shift+Tab shortcut.
pub fn PlanMode::toggle(self : PlanMode) -> Unit {
  match self.status {
    Off => self.status = Planning
    _ => self.status = Off
  }
}

///|
/// Record a plan submitted through the exit tool. Only meaningful while
/// planning; returns false when plan mode is Off.
pub fn PlanMode::submit_plan(self : PlanMode, plan : String) -> Bool {
  match self.status {
    Off => false
    _ => {
      self.status = ReadyForApproval(plan~)
      true
    }
  }
}

///|
/// Approve the pending plan: ReadyForApproval → Off. Returns the approved
/// plan, or None when there is nothing to approve.
pub fn PlanMode::approve(self : PlanMode) -> String? {
  match self.status {
    ReadyForApproval(plan~) => {
      self.status = Off
      Some(plan)
    }
    _ => None
  }
}

///|
/// Reject the pending plan: ReadyForApproval → Planning so the model can
/// revise it. Returns false when there is nothing to reject.
pub fn PlanMode::reject(self : PlanMode) -> Bool {
  match self.status {
    ReadyForApproval(..) => {
      self.status = Planning
      true
    }
    _ => false
  }
}

///|
/// Whether a tool call is allowed under the current status.
fn PlanMode::is_tool_allowed(self : PlanMode, name : String) -> Bool {
  match self.status {
    Off => true
    _ =>
      name == self.config.exit_tool_name ||
      name == self.config.enter_tool_name ||
      self.config.allowed_tools.contains(name)
  }
}
