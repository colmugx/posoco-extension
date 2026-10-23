///|
/// One settled nested call inside a run_code invocation — an append-only
/// terminal fact for flow rendering: the enclosing run_code tool call is the
/// visible node, and each guest `ctx.call` hangs beneath it via
/// `parent_call`. Emitted once per call, after it settles; intermediate
/// states are not observable at the host and are never fabricated.
pub(all) struct NestedCallEvent {
  parent_call : String
  request_id : Int32
  name : String
  arguments : Json
  outcome : Json
} derive(Debug)

///|
pub extend NestedCallEvent with @moonbitlang/core/debug.Debug::{to_repr}
