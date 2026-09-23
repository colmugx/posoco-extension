///|
/// moonbitlang/async/http is unavailable on wasm-gc. Keep the public
/// DecisionPort surface complete and fail as a typed transport limitation.
pub impl @posoco.DecisionPort for JevDecisionPort with fn evaluate(
  _self : JevDecisionPort,
  _request : @posoco.DecisionRequest,
) -> @posoco.DecisionResult raise @posoco.DecisionError {
  raise @posoco.DecisionError::Transport(
    "posoco-ext-jev HTTP transport is unavailable on wasm-gc",
  )
}
