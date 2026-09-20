///|
pub impl @posoco.Extension for PowerShellTools with fn extension_id(_self) -> String {
  "posoco_ext_ps1"
}

///|
pub impl @posoco.Extension for PowerShellTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_ps1", tools=[self], prompt_contributors=[
    self,
  ])
}

///|
pub extend PowerShellTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn ps1_extension() -> PowerShellTools {
  PowerShellTools::PowerShellTools()
}
