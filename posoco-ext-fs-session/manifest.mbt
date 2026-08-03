///|
/// Expose JsonlSessionStore through Posoco's Extension composition API.
pub impl @posoco.Extension for JsonlSessionStore with fn extension_id(
  _self : JsonlSessionStore,
) -> String {
  "posoco_ext_fs_session"
}

///|
pub impl @posoco.Extension for JsonlSessionStore with fn manifest(
  self : JsonlSessionStore,
) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="posoco_ext_fs_session")
  { ..manifest, sessions: [self] }
}

///|
pub extend JsonlSessionStore with @posoco.Extension::{extension_id, manifest}
