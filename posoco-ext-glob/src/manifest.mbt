///|
pub impl @posoco.Extension for GlobTools with fn extension_id(_self) -> String {
  "posoco_ext_glob"
}

///|
pub impl @posoco.Extension for GlobTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_glob", tools=[self])
}

///|
pub extend GlobTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn glob_extension() -> GlobTools {
  GlobTools::GlobTools()
}
