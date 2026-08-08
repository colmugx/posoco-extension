///|

///|
pub impl @posoco.Extension for KimiModelPort with fn extension_id(_self) -> String {
  "posoco_ext_kimi"
}

///|
pub impl @posoco.Extension for KimiModelPort with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_kimi",
    models: [self],
    tools: [],
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
pub extend KimiModelPort with @posoco.Extension::{extension_id, manifest}
