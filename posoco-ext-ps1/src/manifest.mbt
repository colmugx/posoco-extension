///|
pub impl @posoco.Extension for PowerShellTools with fn extension_id(_self) -> String {
  "posoco_ext_ps1"
}

///|
pub impl @posoco.Extension for PowerShellTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_ps1",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [self],
    requires: [],
  }
}

///|
pub extend PowerShellTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn ps1_extension() -> PowerShellTools {
  PowerShellTools::PowerShellTools()
}
