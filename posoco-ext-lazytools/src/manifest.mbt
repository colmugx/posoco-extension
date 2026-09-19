///|
/// Self-report LazyTools' port contributions to the agent composer.
///
/// `id` is the manifest identifier used in composition diagnostics. It is
/// NOT used for routing or persistence.
pub impl @posoco.Extension for LazyTools with fn extension_id(_self) -> String {
  "posoco_ext_lazytools"
}

///|
/// Declare the stable LazyTools surfaces: one ToolProvider exposing the two
/// meta tools, one system-prompt section listing the folded groups, and stable
/// Observer/PipelineHook views that preserve the historical manifest shape
/// without writing usage-driven recent-tool envelopes into durable history.
///
/// The public LazyTools Observer/PipelineHook impls remain available to
/// explicit callers that intentionally opt into the legacy hint behavior.
/// Normal Agent composition receives the stable views below so provider
/// prompt-prefix reuse is not invalidated as recent tool usage changes.
///
/// Deferred providers stay inside the LazyTools value — the host must NOT
/// also register them as extensions, or their tools would appear in the
/// catalog anyway.
pub impl @posoco.Extension for LazyTools with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_lazytools",
    tools=[self],
    observers=[self.stable_observer as &@posoco.Observer],
    hooks=[self.stable_hook as &@posoco.PipelineHook],
    prompt_contributors=[self],
  )
}

///|
/// Expose Extension methods on LazyTools for dot-syntax callers and so
/// `&LazyTools` coerces to `&@posoco.Extension` when placed in an
/// `Array[&@posoco.Extension]`.
pub extend LazyTools with @posoco.Extension::{extension_id, manifest}
