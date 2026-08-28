///|
/// Self-report PlanMode's port contributions to the agent composer.
pub impl @posoco.Extension for PlanMode with fn extension_id(_self) -> String {
  "posoco_ext_plan"
}

///|
/// Declare the ports PlanMode contributes: Hook (tool gating + per-turn
/// reminder injection), ToolProvider (exit_plan_mode + optional
/// enter_plan_mode), CommandPort (plan / plan.approve / plan.reject). The same
/// `self` reference appears under every field so all views share one status.
pub impl @posoco.Extension for PlanMode with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_plan",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    hooks: [self],
    memory: [],
    lifecycle: [],
    commands: [self],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
/// Expose Extension methods on PlanMode for dot-syntax callers and so
/// `&PlanMode` coerces to `&@posoco.Extension` when placed in an
/// `Array[&@posoco.Extension]`.
pub extend PlanMode with @posoco.Extension::{extension_id, manifest}
