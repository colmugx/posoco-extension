///|
pub impl @posoco.Extension for Memoh with fn extension_id(_self : Memoh) -> String {
  "posoco_ext_memoh"
}

///|
/// Memoh contributes an intentionally ephemeral SessionStore plus the
/// current-turn context PipelineHook. Later Memoh-specific surfaces grow on
/// this same adapter object.
pub impl @posoco.Extension for Memoh with fn manifest(self : Memoh) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_memoh", sessions=[self], hooks=[self])
}

///|
pub extend Memoh with @posoco.Extension::{extension_id, manifest}
