///|
pub impl @posoco.Extension for ZaiModelPort with fn extension_id(
  _self : ZaiModelPort,
) -> String {
  "posoco_ext_zai"
}

///|
pub impl @posoco.Extension for ZaiModelPort with fn manifest(
  self : ZaiModelPort,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_zai", models=[self])
}

///|
pub extend ZaiModelPort with @posoco.Extension::{extension_id, manifest}
