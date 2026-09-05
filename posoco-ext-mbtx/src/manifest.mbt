///|
pub impl @posoco.Extension for MbtxTools with fn extension_id(_self) -> String {
  "posoco_ext_mbtx"
}

///|
pub impl @posoco.Extension for MbtxTools with fn manifest(self : MbtxTools) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_mbtx",
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
