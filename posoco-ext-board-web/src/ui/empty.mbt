// Empty-state shell.
//
// RUI owns the frame (centering, spacing, dashed boundary); the caller owns the
// copy and the recovery action.

///|
pub fn empty_shell(children : Array[@html.Html]) -> @html.Html {
  @rui.empty(children)
}
