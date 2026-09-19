///|
pub impl @posoco.Extension for Handoff with fn extension_id(_self : Handoff) -> String {
  "posoco_ext_handoff"
}

///|
pub impl @posoco.Extension for Handoff with fn manifest(self : Handoff) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_handoff", commands=[self])
}

///|
pub extend Handoff with @posoco.Extension::{extension_id, manifest}
