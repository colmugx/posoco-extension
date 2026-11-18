///|
/// Self-report LazyTools' port contributions to the agent composer.
///
/// `id` is the manifest identifier used in composition diagnostics. It is
/// NOT used for routing or persistence.
pub impl @posoco.Extension for LazyTools with fn extension_id(_self) -> String {
  "posoco_ext_lazytools"
}

///|
/// Declare the deferral surfaces: the two meta tools, the operation-boundary
/// exposure projection that hides declared owners from model requests, the
/// stable prompt section listing those owners, and the migration-only hook
/// that removes a legacy recent-tools envelope once.
///
/// `tool_call_owners` is the single source of the invocable face: the kernel
/// admits `tool_execute`'s child calls per owner and computes what `tool_list`
/// may show from the same declaration, so the declared face and the reachable
/// face cannot drift apart.
///
/// Deferred owners are registered by the host as ordinary extensions. The
/// exposure hook — not composition wiring — is what keeps their schemas out of
/// the model request.
pub impl @posoco.Extension for LazyTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_lazytools",
    tools=[self],
    hooks=[
      self.stable_hook as &@posoco.PipelineHook,
      self as &@posoco.PipelineHook,
    ],
    lifecycle=[self],
    prompt_contributors=[self],
    requires=[@posoco.Capability::Decision],
    tool_call_owners=self.owners,
  )
}

///|
/// Expose Extension methods on LazyTools for dot-syntax callers and so
/// `&LazyTools` coerces to `&@posoco.Extension` when placed in an
/// `Array[&@posoco.Extension]`.
pub extend LazyTools with @posoco.Extension::{extension_id, manifest}

///|
/// Capture the optional composed DecisionPort. Absence is normal: semantic
/// fallback is an enhancement over the existing lexical catalog search.
pub impl @posoco.Lifecycle for LazyTools with fn on_compose(
  self : LazyTools,
  ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.decision = ctx.decision()
}

///|
pub extend LazyTools with @posoco.Lifecycle::{on_compose, on_shutdown, on_start}

///|
/// No owned resources; drop the borrowed capability reference at shutdown.
pub impl @posoco.Lifecycle for LazyTools with fn on_shutdown(self : LazyTools) -> Unit {
  self.decision = None
}
