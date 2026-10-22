///|
/// A host-supplied stream observation verdict. Products with their own
/// stream bounds decide what to abort; this package only relays the decision.
pub(all) enum StreamVerdict {
  Continue
  Abort(category~ : String, message~ : String)
}

///|
/// Forward the loop's `done` flag to the inspector and translate its verdict
/// into a transport error. A completed stream must not be re-judged, but that
/// policy belongs to the inspector: zen only forwards the flag it tracks.
fn zen_apply_verdict(
  inspector : ((@posoco.StreamAccumulator, Bool) -> StreamVerdict)?,
  acc : @posoco.StreamAccumulator,
  done~ : Bool,
) -> @posoco.ModelError? {
  match inspector {
    None => None
    Some(inspector) =>
      match inspector(acc, done) {
        Continue => None
        Abort(category~, message~) =>
          Some(
            @posoco.ModelError::Transport(
              "opencode-zen stream aborted (category=" +
              category +
              "): " +
              message,
            ),
          )
      }
  }
}
