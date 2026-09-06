///|
/// Self-report TodoList's port contributions: tools, commands, prompt
/// guidance, and lifecycle. `requires: [Capability::Ui]` is the
/// consumption declaration that makes `ctx.ui()` read Some at compose;
/// the `ui` slot stays EMPTY on purpose — this extension is a UI consumer
/// (it pushes render intents), not a UI provider. Contributing `ui: [self]`
/// would fold it into CompositeUiPort as a render TARGET, inverting the
/// semantics.
pub impl @posoco.Extension for TodoList with fn manifest(self : TodoList) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="posoco_ext_todo")
  {
    ..manifest,
    tools: [self],
    lifecycle: [self],
    commands: [self],
    prompt_contributors: [self],
    requires: [@posoco.Capability::Ui],
  }
}

///|
pub impl @posoco.Extension for TodoList with fn extension_id(_self : TodoList) -> String {
  "posoco_ext_todo"
}

///|
/// The composed UI is delivered once at compose time and stored for the
/// render pushes. With `Ui` declared, the view is always populated (core
/// composes NoopUiPort when no host UI exists), so the None arm is a
/// defensive no-op that keeps the Noop default.
pub impl @posoco.Lifecycle for TodoList with fn on_compose(
  self : TodoList,
  ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  match ctx.ui() {
    Some(ui) => self.ui = ui
    None => ()
  }
}

///|
/// Nothing to release: the list is in-process state with no file
/// persistence and no retained resources beyond the composed UI reference.
pub impl @posoco.Lifecycle for TodoList with fn on_shutdown(self : TodoList) -> Unit {
  ignore(self)
}
