///|
pub impl @posoco.Extension for Skills with fn extension_id(_self) -> String {
  "posoco_ext_skills"
}

///|
/// A populated Skills value contributes both activation/resource tools and,
/// unless disabled by config, the generic catalog prompt. Empty catalogs
/// contribute neither tools nor prompt disclosure. The host-facing `skills`
/// command (catalog listing + host-driven activation) is registered
/// unconditionally: it is user-invoked, and "no skills discovered" is more
/// useful feedback than an unknown command.
pub impl @posoco.Extension for Skills with fn manifest(self) -> @posoco.ExtensionManifest {
  let tools : Array[&@posoco.ToolProvider] = []
  let prompts : Array[&@posoco.SystemPromptContributor] = []
  if !self.catalog.skills.is_empty() {
    tools.push(self)
    if self.config.contribute_prompt && self.config.catalog_max_chars > 0 {
      let rendered = self.catalog.render_prompt_body(
        max_chars=self.config.catalog_max_chars,
        activate_tool_name=self.config.activate_tool_name,
        read_resource_tool_name=self.config.read_resource_tool_name,
      )
      if !rendered.is_empty() {
        prompts.push(self)
      }
    }
  }
  {
    id: "posoco_ext_skills",
    models: [],
    tools,
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [self],
    ui: [],
    prompt_contributors: prompts,
    requires: [],
  }
}

///|
pub extend Skills with @posoco.Extension::{extension_id, manifest}
