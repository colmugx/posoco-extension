///|
/// Default permission posture for coding-agent tools.
pub(all) enum PermissionMode {
  ReadOnly
  WorkspaceWrite
  Interactive
} derive(Eq, Debug)

///|
/// Classifies well-known coding tools and maps them to Posoco's typed
/// PreToolHook decision boundary.
pub(all) struct PermissionPolicy {
  mode : PermissionMode
  read_tools : Array[String]
  write_tools : Array[String]
  shell_tools : Array[String]
}

///|
pub fn PermissionPolicy::new(
  mode : PermissionMode,
) -> PermissionPolicy {
  {
    mode,
    read_tools: ["read", "grep", "glob"],
    write_tools: ["write", "edit", "apply_patch"],
    shell_tools: ["bash", "shell", "sh", "zsh", "cmd", "powershell"],
  }
}

///|
pub fn PermissionPolicy::mode(self : PermissionPolicy) -> PermissionMode {
  self.mode
}

///|
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
pub impl @posoco.PreToolHook for PermissionPolicy with fn before_tool(
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
      if category == "read" || category == "write" {
        @posoco.ToolHookDecision::Approve(call~)
      } else {
        @posoco.ToolHookDecision::Defer(
          reason="permission: tool '" + name + "' requires host approval",
        )
      }
    Interactive =>
      if category == "read" {
        @posoco.ToolHookDecision::Approve(call~)
      } else {
        @posoco.ToolHookDecision::Defer(
          reason="permission: tool '" + name + "' requires confirmation",
        )
      }
  }
}

///|
pub impl @posoco.SystemPromptContributor for PermissionPolicy with fn system_prompt(
  self : PermissionPolicy,
) -> String {
  match self.mode {
    ReadOnly => "Permission mode is read-only. Do not attempt file mutation or shell execution."
    WorkspaceWrite => "Permission mode allows workspace reads and writes. Shell and unknown tools require host approval."
    Interactive => "Permission mode is interactive. Read-only inspection is pre-approved; mutating, shell, and unknown tools require confirmation."
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
  { ..manifest, pre_tool_hooks: [self], prompt_contributors: [self] }
}

///|
pub extend PermissionPolicy with @posoco.Extension::{extension_id, manifest}
