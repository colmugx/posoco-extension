///|
pub impl @posoco.Extension for HerdrReporter with fn extension_id(
  _self : HerdrReporter,
) -> String {
  "posoco_ext_herdr"
}

///|
/// A HerdrReporter contributes one Observer plus itself as Lifecycle (the
/// shutdown-side release of the pane's herdr authority). Everything else
/// stays empty: presence reporting is read-only telemetry and must not
/// widen the composition surface.
pub impl @posoco.Extension for HerdrReporter with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_herdr",
    models: [],
    tools: [],
    sessions: [],
    observers: [self],
    hooks: [],
    memory: [],
    lifecycle: [self],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}
