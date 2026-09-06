///|
pub(all) struct ZcodeExt {
  tools : ZcodeTools
}

///|
pub fn zcode_ext(config? : ZcodeConfig = zcode_config()) -> ZcodeExt {
  { tools: zcode_tools(config~), }
}

///|
pub impl @posoco.Extension for ZcodeExt with fn extension_id(_self : ZcodeExt) -> String {
  "posoco_ext_zcode"
}

///|
/// Manifest contribution: just the tool provider. R1 keeps no resident
/// resources, so the lifecycle stays at its defaults.
pub impl @posoco.Extension for ZcodeExt with fn manifest(self : ZcodeExt) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="posoco_ext_zcode")
  { ..manifest, tools: [self.tools], }
}
