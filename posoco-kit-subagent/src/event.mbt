///|
/// One child-run event forwarded across the event bridge (design §3.3): a
/// `BridgeObserver` attached to the child Agent tags each kernel `TurnEvent`
/// with the child session and kind before pushing it onto the extension's
/// internal multicast channel; hosts subscribe with
/// `subagents.subscribe(fn(SubagentEvent))`.
pub(all) struct SubagentEvent {
  /// Session id of the child run that produced the event (resume key).
  child_session : String
  /// Kind the child was spawned with.
  kind : String
  /// The unmodified kernel event from the child run.
  event : @posoco.TurnEvent
} derive(@debug.Debug)

///|
pub extend SubagentEvent with @moonbitlang/core/debug.Debug::{to_repr}
