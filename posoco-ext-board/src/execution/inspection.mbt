///|
/// Point-in-time owner facts, not a reservation or termination confirmation.
pub(all) struct BoardExecutionOwnerStatus {
  attached : Bool
  closed : Bool
  admission_busy : Bool
  host_available : Bool
  unresolved : Bool
  active : BoardExecutionBinding?
} derive(Eq, Debug)

///|
/// Metadata only; querying status never starts or repairs execution.
///
/// ```mbt check
/// test {
///   let owner = @execution.BoardExecutionOwner(
///     backend=@backend.BoardBackend(),
///     adapter=@execution.PosocoBoardExecutionAdapter(extensions=() => []),
///     store=@execution.MemoryBoardExecutionStore(),
///   )
///   assert_false(owner.status().attached)
///   assert_true(owner.status().active is None)
/// }
/// ```
pub fn BoardExecutionOwner::status(
  self : BoardExecutionOwner,
) -> BoardExecutionOwnerStatus {
  {
    attached: self.loaded,
    closed: self.closed,
    admission_busy: self.busy,
    host_available: self.adapter.ready(),
    unresolved: self.poisoned,
    active: self.active.map(owned => owned.binding),
  }
}

///|
/// Reads the same backend this owner will mutate. Integrations cannot accidentally
/// plan against a different Board while executing through this owner.
///
/// ```mbt check
/// async test {
///   let owner = @execution.BoardExecutionOwner(
///     backend=@backend.BoardBackend(),
///     adapter=@execution.PosocoBoardExecutionAdapter(extensions=() => []),
///     store=@execution.MemoryBoardExecutionStore(),
///   )
///   assert_true(owner.board_state() is Err(@execution.NotReady))
/// }
/// ```
pub async fn BoardExecutionOwner::board_state(
  self : BoardExecutionOwner,
) -> Result[@domain.BoardStateSnapshot, BoardExecutionError] {
  match self.backend.state() {
    Ok(snapshot) => Ok(snapshot)
    Err(_) => Err(NotReady)
  }
}

///|
pub extend BoardExecutionOwnerStatus with Eq::{equal, not_equal}

///|
pub extend BoardExecutionOwnerStatus with @moonbitlang/core/debug.Debug::{
  to_repr,
}
