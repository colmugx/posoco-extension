///|
// ============================================================================
// posoco-ext-kimi — Extension manifest.
//
// KimiModelPort implements `@posoco.ModelPort` (HTTP chat to kimi's
// OpenAI-compatible API). It contributes a single model slot; multi-model
// routing across providers (kimi + OpenAI + Kimi) is the host's concern,
// typically solved by a meta-extension like posoco-ext-llm.
// ============================================================================

///|
pub impl @posoco.Extension for KimiModelPort with fn extension_id(_self) -> String {
  "posoco_ext_kimi"
}

///|
pub impl @posoco.Extension for KimiModelPort with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_kimi",
    models: [self],
    tools: [],
    sessions: [],
    observers: [],
    pre_model_hooks: [],
    pre_tool_hooks: [],
    post_event_hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
  }
}

///|
pub extend KimiModelPort with @posoco.Extension::{extension_id, manifest}
