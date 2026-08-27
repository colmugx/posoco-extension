///|
/// Self-report GoalRunner's port contributions to the agent composer.
pub impl @posoco.Extension for GoalRunner with fn extension_id(_self) -> String {
  "posoco_ext_goal"
}

///|
/// Declare the ports GoalRunner contributes: ToolProvider (plan rewriting)
/// and Observer (turn/token accounting, tool-repetition tracking). There is
/// no SystemPromptContributor — core 0.13.0 assembles the system prompt once
/// per Agent lifetime — so the charter rides the first working turn's user
/// input instead. The same `self` reference appears under every field so the
/// views share one state machine; goal-run turn inputs are driven by
/// `execute`, not by a pipeline hook.
pub impl @posoco.Extension for GoalRunner with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_goal",
    models: [],
    tools: [self],
    sessions: [],
    observers: [self],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
/// Expose Extension methods on GoalRunner for dot-syntax callers and so
/// `&GoalRunner` coerces to `&@posoco.Extension` when placed in an
/// `Array[&@posoco.Extension]`.
pub extend GoalRunner with @posoco.Extension::{extension_id, manifest}

///|
/// Convenience factory: a GoalRunner with default options for the given
/// goal condition. Hosts that need budgets or custom markers build
/// `GoalOptions::default(goal_condition~)` and construct `GoalRunner`
/// directly.
pub fn goal_extension(goal_condition~ : String) -> GoalRunner {
  GoalRunner(options=GoalOptions::default(goal_condition~))
}
