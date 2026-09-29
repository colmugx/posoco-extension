///|
pub struct BoardExtension {
  config : BoardConfig
  runtime_ : @runtime.BoardRuntime
}

///|
pub fn BoardExtension::BoardExtension(
  config? : BoardConfig = BoardConfig::BoardConfig(),
) -> BoardExtension {
  {
    config,
    runtime_: @runtime.BoardRuntime::BoardRuntime(
      event_buffer=config.event_buffer,
    ),
  }
}

///|
pub fn BoardExtension::config(self : BoardExtension) -> BoardConfig {
  self.config
}

///|
/// Runtime facade access is intentionally narrow in S0. It owns telemetry
/// sequencing/history only; Board domain state is introduced in a later stage.
pub fn BoardExtension::runtime(self : BoardExtension) -> @runtime.BoardRuntime {
  self.runtime_
}

///|
pub impl @posoco.Extension for BoardExtension with fn extension_id(
  _self : BoardExtension,
) -> String {
  "posoco_ext_board"
}

///|
/// S0 contributes no active Posoco ports yet. In particular it does not
/// declare Capability::Tasks before Agent-owned work actually exists.
pub impl @posoco.Extension for BoardExtension with fn manifest(
  _self : BoardExtension,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_board")
}

///|
pub extend BoardExtension with @posoco.Extension::{extension_id, manifest}
