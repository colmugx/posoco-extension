///|
// ============================================================================
// posoco-ext-edit — Extension manifest.
// ============================================================================

///|
pub impl @posoco.Extension for EditTools with fn extension_id(_self) -> String {
  "posoco_ext_edit"
}

///|
pub impl @posoco.Extension for EditTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_edit",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    compressors: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [self],
  }
}

///|
pub extend EditTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn edit_extension() -> EditTools {
  EditTools::EditTools()
}
