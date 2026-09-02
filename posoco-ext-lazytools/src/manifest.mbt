///|
/// Self-report LazyTools' port contributions to the agent composer.
///
/// `id` is the manifest identifier used in composition diagnostics. It is
/// NOT used for routing or persistence.
pub impl @posoco.Extension for LazyTools with fn extension_id(_self) -> String {
  "posoco_ext_lazytools"
}

///|
/// Declare the ports LazyTools contributes: one ToolProvider exposing the
/// two meta tools, a system-prompt section listing the folded groups, an
/// Observer recording deferred executions, and a before_model hook hinting
/// recent tools. Deferred providers stay inside the LazyTools value — the
/// host must NOT also register them as extensions, or their tools would
/// appear in the catalog anyway.
pub impl @posoco.Extension for LazyTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_lazytools",
    models: [],
    tools: [self],
    sessions: [],
    observers: [self],
    hooks: [self],
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
