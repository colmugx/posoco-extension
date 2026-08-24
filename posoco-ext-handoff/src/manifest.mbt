///|
pub impl @posoco.Extension for Handoff with fn extension_id(_self : Handoff) -> String {
  "posoco_ext_handoff"
}

///|
pub impl @posoco.Extension for Handoff with fn manifest(self : Handoff) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_handoff",
    models: [],
    tools: [],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [self],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
pub extend Handoff with @posoco.Extension::{extension_id, manifest}
