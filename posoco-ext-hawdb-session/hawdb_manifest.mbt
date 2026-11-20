///|
pub impl @posoco.Extension for HawdbSessionStore with fn extension_id(
  _self : HawdbSessionStore,
) -> String {
  "posoco_ext_hawdb_session"
}

///|
pub impl @posoco.Extension for HawdbSessionStore with fn manifest(
  self : HawdbSessionStore,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_hawdb_session",
    sessions=[self],
  )
}

///|
pub extend HawdbSessionStore with @posoco.Extension::{extension_id, manifest}
