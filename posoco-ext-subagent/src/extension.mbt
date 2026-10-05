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
/// that tracks the parent session and (policy-gated) requests wakeup on the
/// core ready projection, and the lifecycle that captures the composed task
/// and wakeup capabilities. `requires` gates both: the capabilities read
/// `Some` only because they are declared here.
pub impl @posoco.Extension for SubagentTools with fn manifest(
  self : SubagentTools,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_subagent",
    tools=[self],
    hooks=[self as &@posoco.PipelineHook],
    observers=[self as &@posoco.Observer],
    lifecycle=[self as &@posoco.Lifecycle],
    requires=[@posoco.Capability::Tasks, @posoco.Capability::Wakeup],
  )
}
