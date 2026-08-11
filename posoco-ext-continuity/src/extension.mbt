///|
pub struct ContinuityExtension {
  prompt : ContinuityPrompt
}

///|
pub fn continuity_extension() -> ContinuityExtension {
  { prompt: ContinuityPrompt::new() }
}

///|
pub impl @posoco.Extension for ContinuityExtension with fn extension_id(
  _self,
) -> String {
  "posoco_ext_continuity"
}

///|
pub impl @posoco.Extension for ContinuityExtension with fn manifest(
  self,
) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_continuity",
    models: [],
    tools: [],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [self.prompt],
  }
}

///|
pub extend ContinuityExtension with @posoco.Extension::{extension_id, manifest}
