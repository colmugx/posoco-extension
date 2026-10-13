///|
/// Point-in-time detached owner facts, not a reservation or termination
/// confirmation. `active` keeps the first occupied slot's binding for
/// single-slot compatibility; `active_bindings` lists every occupied slot.
pub(all) struct BoardExecutionOwnerStatus {
  attached : Bool
  closed : Bool
  admission_busy : Bool
  host_available : Bool
  unresolved : Bool
  active : BoardExecutionBinding?
  capacity : Int32
  active_bindings : Array[BoardExecutionBinding]
  available_slots : Int32
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
  let actives : Array[BoardExecutionBinding] = []
  for slot in self.slots {
    match slot.execution {
      Some(owned) => actives.push(owned.binding)
      None => ()
    }
  }
  {
    attached: self.loaded,
    closed: self.closed,
    admission_busy: self.busy,
    host_available: self.slots.any(slot => {
      slot.execution is None && slot.adapter.ready()
    }) ||
    self.slots.all(slot => slot.execution is Some(_)),
    unresolved: self.poisoned,
    active: actives.get(0),
    capacity: self.slots.length(),
    active_bindings: actives,
    available_slots: if self.poisoned || self.closed {
      0
    } else {
      self.slots
      .filter(slot => slot.execution is None && slot.adapter.ready())
      .length()
    },
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
