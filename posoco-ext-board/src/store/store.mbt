///|
pub(all) enum BoardStoreError {
  InvalidData(String)
  Io(String)
  Injected(StoreFailureStage)
  /// Replacement has already succeeded; reload before retrying.
  DurabilityUncertain(String)
} derive(Eq, Debug)

///|
pub extend BoardStoreError with Eq::{equal, not_equal}

///|
pub extend BoardStoreError with @debug.Debug::{to_repr}

///|
/// A directory-fsync error is after the visibility boundary: the new board
/// may already be authoritative. All other injected failures are before it.
pub(all) enum StoreFailureStage {
  TempWrite
  TempFsync
  JournalAppend
  JournalFsync
  Rename
  DirectoryFsync
} derive(Eq, Debug)

///|
pub extend StoreFailureStage with Eq::{equal, not_equal}

///|
pub extend StoreFailureStage with @debug.Debug::{to_repr}

///|
/// Snapshot storage only; no domain mutation, event publication or replay.
/// Callers serialize writes. Requests and results are detached.
pub(open) trait BoardStore {
  async fn load(Self) -> Result[BoardLoad, BoardStoreError]
  async fn persist(Self, @domain.BoardStateSnapshot, Array[@domain.BoardEvent]) -> Result[
    Unit,
    BoardStoreError,
  ]
}

///|
pub fn empty_snapshot() -> @domain.BoardStateSnapshot {
  { revision: 0L, tasks: [], attempts: [], }
}

///|
fn copy_snapshot(
  snapshot : @domain.BoardStateSnapshot,
) -> @domain.BoardStateSnapshot {
  snapshot.copy_detached()
}

///|
/// Audit metadata, not a replay instruction or independently allocated revision.
pub(all) struct JournalRecord {
  schema_version : Int
  revision : Int64
  event : @domain.BoardEvent
} derive(Eq, Debug)

///|
pub extend JournalRecord with Eq::{equal, not_equal}

///|
pub extend JournalRecord with @debug.Debug::{to_repr}

///|
pub(all) struct BoardLoad {
  snapshot : @domain.BoardStateSnapshot
  journal : Array[JournalRecord]
} derive(Eq, Debug)

///|
pub extend BoardLoad with Eq::{equal, not_equal}

///|
pub extend BoardLoad with @debug.Debug::{to_repr}

///|
fn records(
  revision : Int64,
  events : Array[@domain.BoardEvent],
) -> Array[JournalRecord] {
  copy_events(events).map(event => { schema_version: 1, revision, event, })
}

///|
fn copy_journal(journal : Array[JournalRecord]) -> Array[JournalRecord] {
  journal.map(record => { ..record, event: copy_events([record.event])[0], })
}

///|
pub struct MemoryBoardStore {
  priv mut snapshot : @domain.BoardStateSnapshot
  priv journal : Array[JournalRecord]
}

///|
pub fn MemoryBoardStore::MemoryBoardStore() -> MemoryBoardStore {
  { snapshot: empty_snapshot(), journal: [], }
}

///|
fn copy_events(events : Array[@domain.BoardEvent]) -> Array[@domain.BoardEvent] {
  events.map(event => {
    match event {
      @domain.DependenciesSet(id~, dependencies~, at_ms~) =>
        @domain.DependenciesSet(id~, dependencies=dependencies.copy(), at_ms~)
      _ => event
    }
  })
}

///|
pub extend MemoryBoardStore with BoardStore::{load, persist}

///|
pub impl BoardStore for MemoryBoardStore with fn load(self) {
  Ok({
    snapshot: copy_snapshot(self.snapshot),
    journal: copy_journal(self.journal),
  })
}

///|
pub impl BoardStore for MemoryBoardStore with fn persist(self, snapshot, events) {
  let snapshot = copy_snapshot(snapshot)
  let events = copy_events(events)
  match encode_snapshot(snapshot) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for event in events {
    match encode_event(event) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  self.snapshot = snapshot
  self.journal.append(records(snapshot.revision, events))
  Ok(())
}

///|
pub(all) struct BoardRecovery {
  changed : Bool
  snapshot : @domain.BoardStateSnapshot
  events : Array[@domain.BoardEvent]
}

///|
/// Pure restart normalization. Time is supplied by the caller; no clock or
/// execution orchestration lives here. One revision covers all changes.
pub fn recover_snapshot(
  snapshot : @domain.BoardStateSnapshot,
  at_ms~ : Int64,
) -> Result[BoardRecovery, BoardStoreError] {
  if at_ms < 0L {
    return Err(InvalidData("recovery time must be nonnegative"))
  }
  match encode_snapshot(snapshot) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let detached = copy_snapshot(snapshot)
  let events : Array[@domain.BoardEvent] = []
  let tasks = detached.tasks.map(task => {
    if task.stage == @domain.Running {
      events.push(
        @domain.TaskStageChanged(
          id=task.id,
          from=@domain.Running,
          to=@domain.Suspended,
          at_ms~,
        ),
      )
      @domain.BoardTask::from_record(
        id=task.id,
        title=task.title,
        description=task.description,
        stage=@domain.Suspended,
        priority=task.priority,
        definition_of_done=task.definition_of_done,
        dependencies=task.dependencies,
        created_at_ms=task.created_at_ms,
        updated_at_ms=at_ms,
        ready_since_ms=None,
      )
    } else {
      task
    }
  })
  let attempts = detached.attempts.map(attempt => {
    if attempt.status == @domain.Running {
      events.push(
        @domain.AttemptFinished(
          id=attempt.id,
          task_id=attempt.task_id,
          outcome=@domain.Interrupted,
          at_ms~,
        ),
      )
      @domain.Attempt::from_record(
        id=attempt.id,
        task_id=attempt.task_id,
        kind=attempt.kind,
        status=@domain.Interrupted,
        review=attempt.review,
        created_at_ms=attempt.created_at_ms,
        started_at_ms=attempt.started_at_ms,
        finished_at_ms=Some(at_ms),
        updated_at_ms=at_ms,
      )
    } else {
      attempt
    }
  })
  let changed = !events.is_empty()
  if changed && snapshot.revision == 9223372036854775807L {
    return Err(InvalidData("recovery revision overflow"))
  }
  Ok({
    changed,
    snapshot: {
      revision: snapshot.revision + (if changed { 1L } else { 0L }),
      tasks,
      attempts,
    },
    events,
  })
}

///|
/// Persist normalization before returning it. Unchanged loads do not write.
/// Returned events are facts for the caller, not EventHub publications.
pub async fn load_recover_persist(
  store : &BoardStore,
  at_ms~ : Int64,
) -> Result[BoardRecovery, BoardStoreError] {
  let snapshot = match store.load() {
    Ok(loaded) => loaded.snapshot
    Err(error) => return Err(error)
  }
  let recovery = match recover_snapshot(snapshot, at_ms~) {
    Ok(recovery) => recovery
    Err(error) => return Err(error)
  }
  if recovery.changed {
    match store.persist(recovery.snapshot, recovery.events) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(recovery)
}
