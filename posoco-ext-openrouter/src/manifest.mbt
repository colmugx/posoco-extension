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
  @posoco.ExtensionManifest(id="posoco_ext_openrouter", models=[self])
}

///|
pub extend OpenRouterModelPort with @posoco.Extension::{extension_id, manifest}
