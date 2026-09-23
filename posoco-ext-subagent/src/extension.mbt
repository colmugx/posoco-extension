///|
pub impl @posoco.Extension for SubagentTools with fn extension_id(
  _self : SubagentTools,
) -> String {
  "posoco_ext_subagent"
}

///|
/// Port contributions: the tool provider, the `before_model` hook that
/// observes delivered background outcomes at the delivery point (it never
/// injects — core owns delivery through the session inbox), the observer
/// that tracks the parent session, and the lifecycle that captures the
/// composed task capability. `requires` gates that delivery: the capability
/// reads `Some` only because it is declared here.
pub impl @posoco.Extension for SubagentTools with fn manifest(
  self : SubagentTools,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_subagent",
    tools=[self],
    hooks=[self as &@posoco.PipelineHook],
    observers=[self as &@posoco.Observer],
    lifecycle=[self as &@posoco.Lifecycle],
    requires=[@posoco.Capability::Tasks],
  )
}
