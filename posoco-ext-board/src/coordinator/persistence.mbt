///|
/// Startup restore keeps recovery persistence behind the same durability
/// boundary as ordinary mutations. If a post-rename failure is uncertain,
/// reload the authoritative snapshot before deciding whether startup may
/// expose the recovered board.
async fn restore_board(
  store : &@store.BoardStore,
  at_ms : Int64,
) -> Result[@store.BoardRecovery, @store.BoardStoreError] {
  let loaded = match store.load() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let previous = loaded.snapshot
  let recovery = match @store.recover_snapshot(previous, at_ms~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !recovery.changed {
    return Ok(recovery)
  }
  match store.persist(recovery.snapshot, recovery.events) {
    Ok(_) => Ok(recovery)
    Err(@store.DurabilityUncertain(detail)) => {
      let authoritative = match store.load() {
        Ok(value) => value.snapshot
        Err(error) => return Err(error)
      }
      if snapshot_matches(authoritative, recovery.snapshot) {
        // The recovered replacement is authoritative. Startup has no
        // mutation caller to refresh, so exposing this reconciled state is
        // the only correct continuation.
        Ok(recovery)
      } else if snapshot_matches(authoritative, previous) {
        // The old board may still contain Running work. Never expose it as
        // Ready without another successful recovery persistence cycle.
        Err(
          @store.DurabilityUncertain(
            detail +
            "; startup recovery reload retained the pre-recovery snapshot",
          ),
        )
      } else {
        Err(
          @store.DurabilityUncertain(
            detail +
            "; startup recovery reload matched neither recovered nor prior snapshot",
          ),
        )
      }
    }
    Err(error) => Err(error)
  }
}

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
      let outcome : Result[@store.BoardRecovery, @store.BoardStoreError] = restore_board(
        store,
        now_ms(),
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
