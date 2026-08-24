///|
pub impl @posoco.Extension for HerdrReporter with fn extension_id(
  _self : HerdrReporter,
) -> String {
  "posoco_ext_herdr"
}

///|
/// A HerdrReporter contributes exactly one Observer. Everything else stays
/// empty: presence reporting is read-only telemetry and must not widen the
/// composition surface.
pub impl @posoco.Extension for HerdrReporter with fn manifest(
  self : HerdrReporter,
) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_herdr",
    models: [],
    tools: [],
    sessions: [],
    observers: [self],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}
