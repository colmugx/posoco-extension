///|

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
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
  }
}

///|
pub extend ShellTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn bash_extension() -> ShellTools {
  ShellTools::ShellTools()
}
