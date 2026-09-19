///|
pub impl @posoco.Extension for ShellTools with fn extension_id(_self) -> String {
  "posoco_ext_bash"
}

///|
pub impl @posoco.Extension for ShellTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_bash", tools=[self])
}

///|
pub extend ShellTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn bash_extension() -> ShellTools {
  ShellTools::ShellTools()
}
