///|
pub impl @posoco.Extension for MbtxTools with fn extension_id(_self) -> String {
  "posoco_ext_mbtx"
}

///|
pub impl @posoco.Extension for MbtxTools with fn manifest(self : MbtxTools) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_mbtx", tools=[self], prompt_contributors=[
    self,
  ])
}
