///|
// ============================================================================
// posoco-ext-deepseek — Extension manifest.
//
// DeepSeekModelPort implements `@posoco.ModelPort` (HTTP chat to DeepSeek's
// OpenAI-compatible API). It contributes a single model slot; multi-model
// routing across providers (DeepSeek + OpenAI + Kimi) is the host's concern,
// typically solved by a meta-extension like posoco-ext-llm.
// ============================================================================

///|
pub impl @posoco.Extension for DeepSeekModelPort with fn extension_id(_self) -> String {
  "posoco_ext_deepseek"
}

///|
pub impl @posoco.Extension for DeepSeekModelPort with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_deepseek",
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
pub extend DeepSeekModelPort with @posoco.Extension::{extension_id, manifest}
