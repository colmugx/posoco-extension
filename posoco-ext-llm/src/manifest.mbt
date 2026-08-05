///|
/// manifest.mbt — Extension impl for RouterModelPort.
///
/// Declares RouterModelPort as a single ModelPort contributor so the
/// Agent's single-model cardinality constraint is satisfied. The router
/// internally manages multiple host-injected model slots.

///|
pub impl @posoco.Extension for RouterModelPort with fn extension_id(
  _self : RouterModelPort,
) -> String {
  "posoco_ext_llm"
}

///|
pub impl @posoco.Extension for RouterModelPort with fn manifest(
  self : RouterModelPort,
) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_llm",
    models: [self],
    tools: [],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [self],
    ui: [],
    prompt_contributors: [],
  }
}

///|
pub extend RouterModelPort with @posoco.Extension::{extension_id, manifest}
