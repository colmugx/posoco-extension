///|
/// posoco_ext_plan — Plan mode extension for Posoco.
///
/// The model investigates and produces a plan under the gates documented
/// on `PlanModeConfig` (read-only shell, docs-only Markdown writes), then
/// submits it via `exit_plan_mode`. Approval UX is product content
/// (`PlanReviewSource` or the `plan.approve` / `plan.reject` commands).
///
/// Usage:
///   let plan = PlanMode::PlanMode(config=PlanModeConfig::{
///     ..PlanModeConfig::default(),
///     allowed_tools: ["read", "glob", "grep", "browser_*"],
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
  /// `read` / `glob` / `grep`). Entries may end with `*` to match a name
  /// prefix — e.g. `browser_*` admits read-only inspection tools surfaced
  /// by MCP bridges. Empty = every tool except the enter/exit tools and
  /// read-only shell commands (see `shell_tools`) is rejected while plan
  /// mode is active.
  allowed_tools : Array[String]
  /// Shell-like tool names gated per invocation: the call passes when its
  /// `cmd` classifies read-only (`@devkit.shell_command_is_read_only`).
  /// Empty disables per-invocation shell gating.
  shell_tools : Array[String]
  /// Write-class tool names gated by TARGET: the call passes only when
  /// its `path` is inside `writable_paths` and ends with one of
  /// `writable_extensions`. Empty disables the target gate.
  write_tools : Array[String]
  /// Directory prefixes writable while planning (default `docs/`).
  writable_paths : Array[String]
  /// File extensions writable while planning (default `.md` only).
  writable_extensions : Array[String]
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
/// Default: read-only shell gating on, writes limited to `docs/**/*.md`,
/// `exit_plan_mode` / `enter_plan_mode` names, model entry disabled.
pub fn PlanModeConfig::default() -> PlanModeConfig {
  {
    allowed_tools: [],
    shell_tools: ["bash", "shell", "sh", "zsh", "cmd", "powershell"],
    write_tools: ["write", "edit", "apply_patch"],
    writable_paths: ["docs/"],
    writable_extensions: [".md"],
    exit_tool_name: "exit_plan_mode",
    allow_model_entry: false,
    enter_tool_name: "enter_plan_mode",
  }
}

///|
/// Central struct: implements PipelineHook + SystemPromptContributor +
/// ToolProvider + CommandPort + Extension on one shared state.
///
/// Pass the same instance to the agent composer once; every port view sees
/// the same mutable status.
pub(all) struct PlanMode {
  config : PlanModeConfig
  /// Optional host-injected review for the exit tool (see `review.mbt`).
  review : &PlanReviewSource?
  /// Verdict recorded by `before_tool` for the exit-tool call it just
  /// reviewed, keyed by call id; consumed by the tool execution.
  mut review_result : (String, PlanReviewDecision)?
  mut status : PlanStatus
}

///|
/// Create a PlanMode with the given configuration, starting `Off`.
///
/// # Example
/// ```mbt check
/// async test "plan mode gates write tools until the plan is approved" {
///   let plan = PlanMode::PlanMode(config=PlanModeConfig::{
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
///     @posoco.ToolDecision::Reject(reason~) =>
///       assert_true(reason.contains("plan mode"))
///     _ => fail("write must be rejected while planning")
///   }
///   let read_call : @posoco.ToolCall = @posoco.ToolCall::{
///     call_id: @posoco.CallId::unchecked("c2"),
///     name: @posoco.ToolName::unchecked("read"),
///     arguments: Json::null(),
///   }
///   match plan.before_tool(read_call) {
///     @posoco.ToolDecision::Approve(..) => ()
///     _ => fail("read must stay available while planning")
///   }
/// }
/// ```
pub fn PlanMode::PlanMode(
  config? : PlanModeConfig = PlanModeConfig::default(),
  review? : &PlanReviewSource? = None,
) -> PlanMode {
  { config, review, review_result: None, status: Off }
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
fn PlanMode::is_tool_allowed(self : PlanMode, name : String) -> Bool {
  match self.status {
    Off => true
    _ =>
      name == self.config.exit_tool_name ||
      name == self.config.enter_tool_name ||
      self.config.allowed_tools
      .iter()
      .any(fn(pattern) { tool_pattern_matches(pattern, name) })
  }
}

///|
fn tool_pattern_matches(pattern : String, name : String) -> Bool {
  if pattern.has_suffix("*") {
    let prefix = pattern.sub(end=pattern.length() - 1)
    prefix.length() > 0 && name.has_prefix(prefix)
  } else {
    pattern == name
  }
}
