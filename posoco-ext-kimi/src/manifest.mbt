///|
pub impl @posoco.Extension for KimiModelPort with fn extension_id(_self) -> String {
  "posoco_ext_kimi"
}

///|
pub impl @posoco.Extension for KimiModelPort with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_kimi", models=[self])
}

///|
pub extend KimiModelPort with @posoco.Extension::{extension_id, manifest}
