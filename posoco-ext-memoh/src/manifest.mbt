///|
pub impl @posoco.Extension for Memoh with fn extension_id(_self : Memoh) -> String {
  "posoco_ext_memoh"
}

///|
/// The foundation contributes only the intentionally ephemeral SessionStore.
/// Memoh-specific prompt/context/MCP hooks are added in later milestones on
/// this same adapter object, keeping all host semantics in one extension.
pub impl @posoco.Extension for Memoh with fn manifest(
  self : Memoh,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_memoh", sessions=[self])
}

///|
pub extend Memoh with @posoco.Extension::{extension_id, manifest}
