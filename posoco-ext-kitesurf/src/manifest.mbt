///|
pub impl @posoco.Extension for KitesurfTools with fn extension_id(_self) -> String {
  "posoco_ext_kitesurf"
}

///|
pub impl @posoco.Extension for KitesurfTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_kitesurf", tools=[self])
}

///|
pub extend KitesurfTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn kitesurf_extension(config : KitesurfConfig) -> KitesurfTools {
  KitesurfTools::KitesurfTools(config~)
}
