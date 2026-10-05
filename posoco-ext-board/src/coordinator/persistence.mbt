///|
/// All store IO is Supervisor-owned; workers only report results to the actor.
fn spawn_restore_worker(
  core : CoordinatorCore,
  actor : @fuwaroid.Fuwaroid[BoardMsg, BoardQuery, BoardReply],
) -> Unit {
  let store = core.store
  let now_ms = core.now_ms
  let admitted = core.supervisor.spawn(
    () => {
      let outcome : Result[@store.BoardRecovery, @store.BoardStoreError] = @store.load_recover_persist(
        store,
        at_ms=now_ms(),
      ) catch {
        error => Err(@store.Io(error.to_string()))
      }
      let _ = actor.tell(Worker(Restored(outcome)))
    },
    label="board-restore",
  )
  match admitted {
    Ok(_) => ()
    Err(_) => {
      let _ = actor.tell(
        Worker(
          Restored(Err(@store.Io("board restore worker was not admitted"))),
        ),
      )
    }
  }
}

///|
fn spawn_persist_worker(
  core : CoordinatorCore,
  actor : @fuwaroid.Fuwaroid[BoardMsg, BoardQuery, BoardReply],
  ticket : Int64,
  snapshot : @domain.BoardStateSnapshot,
  events : Array[@domain.BoardEvent],
) -> Bool {
  let store = core.store
  match
    core.supervisor.spawn(
      () => {
        let outcome : Result[Unit, @store.BoardStoreError] = store.persist(
          snapshot, events,
        ) catch {
          // A raised error does not prove which side of rename the store reached.
          error => Err(@store.DurabilityUncertain(error.to_string()))
        }
        let _ = actor.tell(Worker(Persisted(ticket~, outcome~)))
      },
      label="board-persist",
    ) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn spawn_reload_worker(
  core : CoordinatorCore,
  actor : @fuwaroid.Fuwaroid[BoardMsg, BoardQuery, BoardReply],
  ticket : Int64,
) -> Bool {
  let store = core.store
  match
    core.supervisor.spawn(
      () => {
        let outcome : Result[@domain.BoardStateSnapshot, @store.BoardStoreError] = store
          .load()
          .map(loaded => loaded.snapshot) catch {
            error => Err(@store.Io(error.to_string()))
          }
        let _ = actor.tell(Worker(Reloaded(ticket~, outcome~)))
      },
      label="board-reconcile",
    ) {
    Ok(_) => true
    Err(_) => false
  }
}
