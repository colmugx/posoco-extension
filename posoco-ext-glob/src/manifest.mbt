///|
// ============================================================================
// posoco-ext-glob — Extension manifest.
// ============================================================================

///|
pub impl @posoco.Extension for GlobTools with fn extension_id(_self) -> String {
  "posoco_ext_glob"
}

///|
pub impl @posoco.Extension for GlobTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_glob",
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
pub extend GlobTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn glob_extension() -> GlobTools {
  GlobTools::GlobTools()
}
