///|

///|
pub impl @posoco.Extension for DeepSeekModelPort with fn extension_id(_self) -> String {
  "posoco_ext_deepseek"
}

///|
pub impl @posoco.Extension for DeepSeekModelPort with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_deepseek",
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
    requires: [],
  }
}

///|
pub extend DeepSeekModelPort with @posoco.Extension::{extension_id, manifest}
