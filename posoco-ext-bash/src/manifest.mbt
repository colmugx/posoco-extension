///|
// ============================================================================
// posoco-ext-bash — Extension manifest.
// ============================================================================

///|
pub impl @posoco.Extension for ShellTools with fn extension_id(_self) -> String {
  "posoco_ext_bash"
}

///|
pub impl @posoco.Extension for ShellTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_bash",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    pre_model_hooks: [],
    pre_tool_hooks: [],
    post_event_hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [self],
  }
}

///|
pub extend ShellTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn bash_extension() -> ShellTools {
  ShellTools::ShellTools()
}
