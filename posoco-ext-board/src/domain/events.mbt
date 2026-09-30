///|
/// Typed facts produced by accepted mutations, in order. S3A never
/// publishes these to the telemetry EventHub; delivery is a later stage.
pub(all) enum BoardEvent {
  TaskCreated(id~ : BoardTaskId, at_ms~ : Int64)
  TaskUpdated(id~ : BoardTaskId, at_ms~ : Int64)
  DependenciesSet(
    id~ : BoardTaskId,
    dependencies~ : Array[BoardTaskId],
    at_ms~ : Int64
  )
  TaskStageChanged(
    id~ : BoardTaskId,
    from~ : BoardStage,
    to~ : BoardStage,
    at_ms~ : Int64
  )
  AttemptQueued(
    id~ : AttemptId,
    task_id~ : BoardTaskId,
    kind~ : AttemptKind,
    at_ms~ : Int64
  )
  AttemptStarted(id~ : AttemptId, task_id~ : BoardTaskId, at_ms~ : Int64)
  AttemptFinished(
    id~ : AttemptId,
    task_id~ : BoardTaskId,
    outcome~ : AttemptOutcome,
    at_ms~ : Int64
  )
  ReviewRecorded(
    id~ : AttemptId,
    task_id~ : BoardTaskId,
    decision~ : ReviewDecision,
    at_ms~ : Int64
  )
} derive(Eq, Debug)

///|
pub extend BoardEvent with Eq::{equal, not_equal}

///|
pub extend BoardEvent with @moonbitlang/core/debug.Debug::{to_repr}
