///|
pub impl @posoco.Extension for EditTools with fn extension_id(_self) -> String {
  "posoco_ext_edit"
}

///|
pub impl @posoco.Extension for EditTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_edit", tools=[self])
}

///|
pub extend EditTools with @posoco.Extension::{extension_id, manifest}

///|
pub fn edit_extension() -> EditTools {
  EditTools::EditTools()
}
