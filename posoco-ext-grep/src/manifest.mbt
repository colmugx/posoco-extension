///|

///|
pub impl @posoco.Extension for GrepTools with fn extension_id(_self) -> String {
  "posoco_ext_grep"
}

///|
pub impl @posoco.Extension for GrepTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_grep", tools=[self])
}

///|
pub extend GrepTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn grep_extension() -> GrepTools {
  GrepTools::GrepTools()
}
