///|
/// Self-reported port view: this extension contributes exactly one ModelPort
/// (the OpenRouter chat completions adapter). ApiKey login and catalog
/// construction live on `OpenRouterProvider`; the manifest advertises the
/// port trait view the Agent composer consumes.

///|
pub impl @posoco.Extension for OpenRouterModelPort with fn extension_id(
  _self : OpenRouterModelPort,
) -> String {
  "posoco_ext_openrouter"
}

///|
pub impl @posoco.Extension for OpenRouterModelPort with fn manifest(
  self : OpenRouterModelPort,
) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_openrouter",
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
pub extend OpenRouterModelPort with @posoco.Extension::{extension_id, manifest}
