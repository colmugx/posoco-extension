///|
pub impl @posoco.Extension for QwenModelPort with fn extension_id(
  _self : QwenModelPort,
) -> String {
  "posoco_ext_qwen"
}

///|
pub impl @posoco.Extension for QwenModelPort with fn manifest(
  self : QwenModelPort,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_qwen", models=[self])
}

///|
pub extend QwenModelPort with @posoco.Extension::{extension_id, manifest}
