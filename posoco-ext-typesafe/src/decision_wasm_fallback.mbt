///|
/// moonbitlang/async/http is unavailable on wasm-gc. Keep the public
/// DecisionPort surface complete and fail as a typed transport limitation.
pub impl @posoco.DecisionPort for TypesafeDecisionPort with fn evaluate(
  _self : TypesafeDecisionPort,
  _request : @posoco.DecisionRequest,
) -> @posoco.DecisionResult raise @posoco.DecisionError {
  raise @posoco.DecisionError::Transport(
    "posoco-ext-typesafe HTTP transport is unavailable on wasm-gc",
  )
}
