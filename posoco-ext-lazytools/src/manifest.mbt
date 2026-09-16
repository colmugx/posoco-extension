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
/// meta tools and one system-prompt section listing the folded groups.
///
/// The legacy Observer/PipelineHook impls remain available to explicit
/// callers, but are intentionally not auto-registered here. Their
/// recent-tools envelope is usage-driven and therefore rewrites durable
/// transcript history as tool usage changes, which moves the provider prompt
/// prefix boundary backwards and defeats prefix-cache reuse. The stable
/// system prompt instead tells the model to reuse schemas already present in
/// conversation history and call `tool_list` only when it still needs one.
///
/// Deferred providers stay inside the LazyTools value — the host must NOT
/// also register them as extensions, or their tools would appear in the
/// catalog anyway.
pub impl @posoco.Extension for LazyTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_lazytools",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [self],
    requires: [],
  }
}

///|
/// Expose Extension methods on LazyTools for dot-syntax callers and so
/// `&LazyTools` coerces to `&@posoco.Extension` when placed in an
/// `Array[&@posoco.Extension]`.
pub extend LazyTools with @posoco.Extension::{extension_id, manifest}
