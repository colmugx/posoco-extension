///|
/// Default permission posture for coding-agent tools.
pub(all) enum PermissionMode {
  ReadOnly
  WorkspaceWrite
  Interactive
} derive(Eq, Debug)

///|
/// What the policy wants the host to approve. The host renders this however
/// it likes (modal, inline prompt) and returns a decision.
pub(all) struct ApprovalRequest {
  /// Tool name as it appears in the ToolCall.
  tool_name : String
  /// Stable call id, for correlation in the UI.
  call_id : String
  /// Policy classification: "read" | "write" | "shell" | "unknown".
  category : String
  /// Truncated argument preview, for the user to see what will run. The
  /// policy truncates to a bounded length so secrets/large payloads do not
  /// flood the prompt.
  arguments_preview : String
}

///|
/// The host's verdict. `AllowSession` and `AllowAlways` are recorded in the
/// policy's session cache so subsequent calls to the same tool skip the
/// prompt. v0 treats `AllowAlways` as session-scoped (no on-disk persistence).
pub(all) enum ApprovalDecision {
  /// Approve this one call only; do not cache.
  AllowOnce
  /// Approve and remember for the rest of this agent's lifetime.
  AllowSession
  /// Approve and remember; v0 equivalent to AllowSession (no persistence).
  AllowAlways
  /// Reject the call. The reason is surfaced to the model as a tool error.
  Deny(reason~ : String)
}

///|
/// Host-implemented approval source. `ask` is `async` because
/// `Hook::before_tool` is `async`; a host that needs UI interaction (e.g.
/// the js host blocking on `UiPort::request` via `.wait()`) can suspend
/// inside `ask`. A host that decides synchronously implements `ask` as a
/// plain `fn` — a sync `fn` satisfies an `async` trait slot under MoonBit's
/// colorless-coroutine model.
pub(open) trait ApprovalSource {
  async fn ask(Self, request : ApprovalRequest) -> ApprovalDecision
}

// ──────────────────────────────────────────────────────────────────────────
// PermissionPolicy
// ──────────────────────────────────────────────────────────────────────────

///|
/// Classifies well-known coding tools and gates them through the approval
/// source. Construct once per agent; the same struct is the `Hook`,
/// `SystemPromptContributor`, and `Extension`.
pub(all) struct PermissionPolicy {
  mode : PermissionMode
  /// None ⇒ behave as pure-mode (no approval prompt; ReadOnly rejects,
  /// WorkspaceWrite/Interactive would need a source). A None source on a
  /// non-ReadOnly mode treats every non-read tool as denied.
  approval : &ApprovalSource?
  /// Tools approved with AllowSession/AllowAlways this agent lifetime.
  mut session_approved : Set[String]
  read_tools : Array[String]
  write_tools : Array[String]
  shell_tools : Array[String]
}

///|
/// Construct a policy. `approval` is optional so a host can run ReadOnly
/// without wiring up a UI; non-ReadOnly modes without a source deny every
/// non-read tool.
pub fn PermissionPolicy::new(
  mode : PermissionMode,
  approval? : &ApprovalSource? = None,
) -> PermissionPolicy {
  {
    mode,
    approval,
    session_approved: Set([]),
    read_tools: ["read", "grep", "glob"],
    write_tools: ["write", "edit", "apply_patch"],
    shell_tools: ["bash", "shell", "sh", "zsh", "cmd", "powershell"],
  }
}

///|
/// Read-only accessor for the active mode.
pub fn PermissionPolicy::mode(self : PermissionPolicy) -> PermissionMode {
  self.mode
}

///|
/// Classify a tool name into a category bucket.
fn PermissionPolicy::classify(self : PermissionPolicy, name : String) -> String {
  if self.read_tools.contains(name) {
    "read"
  } else if self.write_tools.contains(name) {
    "write"
  } else if self.shell_tools.contains(name) {
    "shell"
  } else {
    "unknown"
  }
}

///|
/// Truncate arguments to a bounded preview so the approval prompt stays
/// readable. Long payloads and secrets are clipped, not echoed in full.
fn preview_arguments(args : Json) -> String {
  let raw = args.stringify()
  if raw.length() <= 80 {
    raw
  } else {
    raw.sub(end=77).to_owned() + "..."
  }
}

///|
/// Ask the approval source (if any) and apply its decision. Returns true if
/// the call is approved (now or from the session cache), false otherwise.
/// `async` because the approval source may suspend (e.g. js host blocking on
/// a UI confirm); reads/shell classification itself is synchronous.
async fn PermissionPolicy::gate(
  self : PermissionPolicy,
  call : @posoco.ToolCall,
  category : String,
) -> @posoco.ToolHookDecision {
  let name = call.name.to_string()
  // Session cache hit: a prior AllowSession/AllowAlways for this tool.
  if self.session_approved.contains(name) {
    return @posoco.ToolHookDecision::Approve(call~)
  }
  match self.approval {
    None =>
      @posoco.ToolHookDecision::Reject(
        reason="permission: no approval source configured for '" + name + "'",
      )
    Some(source) => {
      let request : ApprovalRequest = {
        tool_name: name,
        call_id: call.call_id.to_string(),
        category,
        arguments_preview: preview_arguments(call.arguments),
      }
      match source.ask(request) {
        AllowOnce => @posoco.ToolHookDecision::Approve(call~)
        AllowSession => {
          self.session_approved.add(name)
          @posoco.ToolHookDecision::Approve(call~)
        }
        AllowAlways => {
          // v0: no on-disk persistence; treat as session-scoped.
          self.session_approved.add(name)
          @posoco.ToolHookDecision::Approve(call~)
        }
        Deny(reason~) =>
          @posoco.ToolHookDecision::Reject(
            reason="permission: denied '" + name + "': " + reason,
          )
      }
    }
  }
}

///|
pub impl @posoco.Hook for PermissionPolicy with fn before_tool(
  self : PermissionPolicy,
  call : @posoco.ToolCall,
) -> @posoco.ToolHookDecision {
  let name = call.name.to_string()
  let category = self.classify(name)
  match self.mode {
    ReadOnly =>
      if category == "read" {
        @posoco.ToolHookDecision::Approve(call~)
      } else {
        @posoco.ToolHookDecision::Reject(
          reason="permission: read-only mode rejected tool '" + name + "'",
        )
      }
    WorkspaceWrite =>
      if category == "read" {
        @posoco.ToolHookDecision::Approve(call~)
      } else {
        // writes/shell/unknown go through the approval gate.
        self.gate(call, category)
      }
    Interactive =>
      if category == "read" {
        @posoco.ToolHookDecision::Approve(call~)
      } else {
        // every side-effecting tool goes through the approval gate.
        self.gate(call, category)
      }
  }
}

///|
pub impl @posoco.SystemPromptContributor for PermissionPolicy with fn system_prompt(
  self : PermissionPolicy,
) -> String {
  match self.mode {
    ReadOnly =>
      "Permission mode is read-only. Do not attempt file mutation or shell execution."
    WorkspaceWrite =>
      "Permission mode allows workspace reads and writes. Shell and unknown tools require host approval."
    Interactive =>
      "Permission mode is interactive. Read-only inspection is pre-approved; mutating, shell, and unknown tools require confirmation."
  }
}

///|
pub impl @posoco.Extension for PermissionPolicy with fn extension_id(
  _self : PermissionPolicy,
) -> String {
  "posoco_ext_permission"
}

///|
pub impl @posoco.Extension for PermissionPolicy with fn manifest(
  self : PermissionPolicy,
) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="posoco_ext_permission")
  { ..manifest, hooks: [self], prompt_contributors: [self] }
}

///|
pub extend PermissionPolicy with @posoco.Extension::{extension_id, manifest}
