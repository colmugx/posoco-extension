///|
/// Self-report StatusBar's port contributions: the /statusbar listing
/// command and the lifecycle view that receives the composed UI.
/// `requires: [Capability::Ui]` is the consumption declaration that makes
/// `ctx.ui()` read Some at compose; the `ui` slot stays EMPTY on purpose —
/// the bridge is a UI consumer (it pushes render intents), not a UI
/// provider. There is no Observer: the bridge has zero data knowledge.
pub impl @posoco.Extension for StatusBar with fn manifest(self : StatusBar) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="posoco_ext_statusbar")
  {
    ..manifest,
    lifecycle: [self],
    commands: [self],
    requires: [@posoco.Capability::Ui],
  }
}

///|
pub impl @posoco.Extension for StatusBar with fn extension_id(_self : StatusBar) -> String {
  "posoco_ext_statusbar"
}

///|
/// The composed UI is delivered once at compose time and stored for the
/// render pushes. With `Ui` declared, the view is always populated (core
/// composes NoopUiPort when no host UI exists), so the None arm keeps the
/// silent pre-compose behavior.
pub impl @posoco.Lifecycle for StatusBar with fn on_compose(
  self : StatusBar,
  ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  match ctx.ui() {
    Some(ui) => self.ui = Some(ui)
    None => ()
  }
}

///|
/// Nothing to release: the registry is in-process state with no retained
/// resources beyond the composed UI reference.
pub impl @posoco.Lifecycle for StatusBar with fn on_shutdown(self : StatusBar) -> Unit {
  ignore(self)
}

///|
/// Expose Extension methods on StatusBar for dot-syntax callers and so
/// `&StatusBar` coerces to `&@posoco.Extension` when placed in an
/// `Array[&@posoco.Extension]`.
pub extend StatusBar with @posoco.Extension::{extension_id, manifest}
