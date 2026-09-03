///|
/// Manifest: tools, a before_tool consent hook, lifecycle, commands, and a
/// system-prompt contribution, all on the same struct. `requires: [Ui]`
/// delivers the composed UI for destructive-write consent at on_compose.
pub impl @posoco.Extension for ObsidianTools with fn extension_id(
  _self : ObsidianTools,
) -> String {
  OBSIDIAN_OWNER
}

///|
pub impl @posoco.Extension for ObsidianTools with fn manifest(
  self : ObsidianTools,
) -> @posoco.ExtensionManifest {
  {
    id: OBSIDIAN_OWNER,
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    hooks: [self],
    memory: [],
    lifecycle: [self],
    commands: [self],
    ui: [],
    prompt_contributors: [self],
    requires: [@posoco.Capability::Ui],
  }
}

///|
/// Expose Extension methods for dot-syntax callers and so `&ObsidianTools`
/// coerces to `&@posoco.Extension` in an `Array[&@posoco.Extension]`.
pub extend ObsidianTools with @posoco.Extension::{extension_id, manifest}

///|
pub extend ObsidianTools with @posoco.ToolProvider::{list_tools, execute}

///|
pub extend ObsidianTools with @posoco.SystemPromptContributor::{system_prompt}
