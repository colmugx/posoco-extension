///|
/// posoco_ext_plan — Plan mode extension for Posoco.
///
/// The model investigates and produces a plan under the gates documented
/// on `PlanModeConfig` (read-only shell, Markdown-only writes anywhere in
/// the workspace), then submits it via `exit_plan_mode`. Approval UX is
/// product content (`PlanReviewSource` — Accept / Revise(feedback) /
/// Dismiss — or the `plan.approve` / `plan.reject` / `plan.dismiss`
/// commands).
///
/// Usage:
///   let plan = PlanMode::PlanMode(config=PlanModeConfig::{
///     ..PlanModeConfig::default(),
///     allow_model_entry: true,
///   })
///   let agent = Agent(exts=[plan], config=...)
///   // Enter/inspect plan mode through the `plan` command; the state
///   // machine itself is driven by the tools and commands above.

///|
/// Plan mode state machine.
///
/// - `Off`: all hooks pass through; no per-turn reminder is injected.
/// - `Planning`: non-allowed tools are rejected; a per-turn plan reminder is
///   injected before the model.
/// - `ReadyForApproval`: the model called `exit_plan_mode`; still gated until
///   the product approves (→ `Off`) or rejects (→ `Planning`).
pub(all) enum PlanStatus {
  Off
  Planning
  ReadyForApproval(name~ : String, plan~ : String)
} derive(Eq, Debug)

///|
pub extend PlanStatus with Eq::{not_equal, equal}

///|
pub extend PlanStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for PlanStatus with fn to_string(self : PlanStatus) -> String {
  match self {
    Off => "Off"
    Planning => "Planning"
    // The plan text stays out of the rendering — a status line identifies
    // the pending plan by name, not by dumping its body.
    ReadyForApproval(name~, plan~) =>
      "ReadyForApproval(name=\{name}, plan=\{plan.length()} chars)"
  }
}

///|
pub extend PlanStatus with Show::{to_string, output}

///|
/// Plan-mode gate configuration: a WRITE BLOCK, not an allow-list. While
/// planning, `shell_tools` are gated per invocation (read-only commands
/// only) and `write_tools` are gated by target (`writable_extensions`
/// only); every other tool passes through to the permission lattice.
pub(all) struct PlanModeConfig {
  /// Shell-like tool names gated per invocation: the call passes when its
  /// `cmd` classifies read-only per this package's read-only classifier
  /// (shell_readonly.mbt). Empty disables per-invocation shell gating.
  shell_tools : Array[String]
  /// Write-class tool names gated by TARGET: the call passes only when its
  /// `path` ends with one of `writable_extensions`. Workspace confinement is
  /// NOT re-checked here — the write tools' own anchoring already confines
  /// them to the workspace. Empty disables the target gate.
  write_tools : Array[String]
  /// File extensions writable while planning (default `.md` only — notes
  /// and draft plans anywhere in the workspace).
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
pub extend PlanModeConfig with Eq::{not_equal, equal}

///|
pub extend PlanModeConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn PlanModeConfig::default() -> PlanModeConfig {
  {
    shell_tools: ["bash", "shell", "sh", "zsh", "cmd", "powershell"],
    write_tools: ["write", "edit", "apply_patch"],
    writable_extensions: [".md"],
    exit_tool_name: "exit_plan_mode",
    allow_model_entry: false,
    enter_tool_name: "enter_plan_mode",
  }
}

///|
/// Central struct: implements PipelineHook (tool gating + per-turn reminder
/// injection) + ToolProvider + CommandPort + Extension on one shared state.
///
/// Pass the same instance to the agent composer once; every port view sees
/// the same mutable status.
pub(all) struct PlanMode {
  config : PlanModeConfig
  /// Optional host-injected review for the exit tool (see `review.mbt`).
  review : &PlanReviewSource?
  /// Optional cross-extension bus: carries the tool-exemption report at
  /// construction and plan-status facts on every transition.
  bus : @devkit.EventBus?
  /// Optional workspace filesystem for plan-file persistence (see
  /// `plan_file.mbt`); without it planning stays in-memory.
  fs : &@workspace.WorkspaceFs?
  /// Session label for plan file names; set at construction or per session
  /// via `set_session_name` (hosts that mint session ids later).
  mut session_name : String
  /// Accumulated planning narrative and how many assistant messages it
  /// already covers (see `record_draft_delta`).
  mut draft : String
  mut draft_recorded : Int
  mut status : PlanStatus
  /// Last status processed by `before_model`. Tracks transitions to `Off` so
  /// a one-time exit reminder is emitted only on the first turn after leaving
  /// plan mode.
  mut prev_status : PlanStatus
}

///|
/// Create a PlanMode with the given configuration, starting `Off`.
///
/// # Example
/// ```mbt check
/// async test "plan mode gates write tools until the plan is approved" {
///   let plan = @posoco-ext-plan.PlanMode::PlanMode(config=@posoco-ext-plan.PlanModeConfig::{
///     ..@posoco-ext-plan.PlanModeConfig::default(),
///   })
///   ignore(plan.invoke("plan", Json::string("on")))
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
  bus? : @devkit.EventBus? = None,
  fs? : &@workspace.WorkspaceFs? = None,
  session_name? : String = "",
) -> PlanMode {
  // Report the enter/exit tools on the `tool_exemptions` bus topic so a
  // subscribed permission gate lets them bypass its approval asks — their
  // governance lives here (the plan-review seam), not there. Fire-and-
  // forget: the receiving gate must already be subscribed, i.e. hosts
  // construct the policy before this constructor runs.
  match bus {
    Some(bus) => {
      let tools : Array[String] = [config.exit_tool_name]
      if config.allow_model_entry {
        tools.push(config.enter_tool_name)
      }
      publish_tool_exemptions(bus, tools~)
    }
    None => ()
  }
  {
    config,
    review,
    bus,
    fs,
    session_name,
    draft: "",
    draft_recorded: 0,
    status: Off,
    prev_status: Off,
  }
}

///|
/// Set the session label used in plan file names. Hosts that mint session
/// ids after construction call this when a session starts; it does not
/// touch plan state.
pub fn PlanMode::set_session_name(self : PlanMode, name : String) -> Unit {
  self.session_name = name
}

///|
/// Publish the plan status on the bus so peers (status bar, host UI) can
/// render it without polling. Convention: the devkit status protocol —
/// segment `"plan"` at priority 10, value `"Plan"` while planning or
/// awaiting approval, unregistered once off. Register is idempotent on the
/// consumer side (the owner's re-register keeps `first_seen`), so calling
/// it on every active transition is safe.
fn PlanMode::publish_status(self : PlanMode) -> Unit {
  match self.bus {
    Some(bus) =>
      match self.status {
        Off =>
          @devkit.publish_status_unregister(
            bus,
            source="posoco_ext_plan",
            segment="plan",
          )
        Planning =>
          @devkit.publish_status_register(
            bus,
            source="posoco_ext_plan",
            segment="plan",
            priority=10,
            value="Plan",
            color="accent",
          )
        // While a plan waits, the status bar names it — the wait can span
        // turns, and a bare "Plan" stops telling the user what is pending.
        ReadyForApproval(name~, ..) =>
          @devkit.publish_status_register(
            bus,
            source="posoco_ext_plan",
            segment="plan",
            priority=10,
            value="Plan: \{name}",
            color="accent",
          )
      }
    None => ()
  }
}

///|
pub fn PlanMode::status(self : PlanMode) -> PlanStatus {
  self.status
}

///|
/// Enter plan mode. Idempotent: re-entering restarts planning and drops any
/// plan awaiting approval.
fn PlanMode::start(self : PlanMode) -> Unit {
  self.status = Planning
  // Each planning session restarts the narrative; the draft file is
  // overwritten lazily on the first new content.
  self.draft = ""
  self.draft_recorded = 0
  self.publish_status()
}

///|
/// Leave plan mode unconditionally, discarding any pending plan.
pub fn PlanMode::stop(self : PlanMode) -> Unit {
  self.status = Off
  self.publish_status()
}

///|
/// Toggle plan mode: Off → Planning, anything else → Off. Backs the bare
/// `/plan` command and the Shift+Tab shortcut.
fn PlanMode::toggle(self : PlanMode) -> Unit {
  match self.status {
    Off => self.status = Planning
    _ => self.status = Off
  }
  self.publish_status()
}

///|
/// Record a plan submitted through the exit tool. Only meaningful while
/// planning; returns false when plan mode is Off.
fn PlanMode::submit_plan(self : PlanMode, name : String, plan : String) -> Bool {
  match self.status {
    Off => false
    _ => {
      self.status = ReadyForApproval(name~, plan~)
      self.publish_status()
      true
    }
  }
}

///|
/// Approve the pending plan: ReadyForApproval → Off. Returns the approved
/// plan's (name, text), or None when there is nothing to approve.
fn PlanMode::approve(self : PlanMode) -> (String, String)? {
  match self.status {
    ReadyForApproval(name~, plan~) => {
      self.status = Off
      self.publish_status()
      Some((name, plan))
    }
    _ => None
  }
}

///|
/// Reject the pending plan: ReadyForApproval → Planning so the model can
/// revise it. Returns false when there is nothing to reject.
fn PlanMode::reject(self : PlanMode) -> Bool {
  match self.status {
    ReadyForApproval(..) => {
      self.status = Planning
      self.publish_status()
      true
    }
    _ => false
  }
}

///|
/// Dismiss the pending plan: ReadyForApproval → Off, discarding the plan.
/// The command-flow counterpart of the review `Dismiss` verdict. Returns
/// false when there is nothing to dismiss.
fn PlanMode::dismiss(self : PlanMode) -> Bool {
  match self.status {
    ReadyForApproval(..) => {
      self.status = Off
      self.publish_status()
      true
    }
    _ => false
  }
}
