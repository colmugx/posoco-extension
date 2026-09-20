///|
/// Self-report Profiles' port contributions to the agent composer.

///|
pub impl @posoco.Extension for Profiles with fn extension_id(_self : Profiles) -> String {
  "posoco_ext_profiles"
}

///|
/// One ToolProvider (activate_profile), one Observer (session usage),
/// one before_model hook (activation injection), one prompt contributor
/// (the menu), one CommandPort (/profiles, /profile save), one Lifecycle
/// (UiPort wiring).
///
/// Host wiring notes: register this extension BEFORE lazytools (Q17 — hook
/// chains run in registration order, so the lazytools envelope stays last),
/// and register deep-deferred views (`deep_defer_extensions`) instead of
/// the originals for member extensions, or their prompts would still be
/// resident and activation would double-inject (F2).
pub impl @posoco.Extension for Profiles with fn manifest(self : Profiles) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_profiles",
    tools=[self],
    observers=[self],
    hooks=[self],
    lifecycle=[self],
    commands=[self],
    prompt_contributors=[self],
    requires=[@posoco.Capability::Ui],
  )
}
