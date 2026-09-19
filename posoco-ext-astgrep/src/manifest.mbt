///|
pub impl @posoco.Extension for AstGrepTools with fn extension_id(_self) -> String {
  "posoco_ext_astgrep"
}

///|
pub impl @posoco.Extension for AstGrepTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_astgrep", tools=[self])
}

///|
pub extend AstGrepTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn astgrep_extension() -> AstGrepTools {
  AstGrepTools::AstGrepTools()
}
