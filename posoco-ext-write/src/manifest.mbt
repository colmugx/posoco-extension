///|

///|
pub impl @posoco.Extension for WriteTools with fn extension_id(_self) -> String {
  "posoco_ext_write"
}

///|
pub impl @posoco.Extension for WriteTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_write", tools=[self])
}

///|
pub extend WriteTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn write_extension() -> WriteTools {
  WriteTools::WriteTools()
}
