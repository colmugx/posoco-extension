///|
/// Typed facts produced by accepted mutations, in order. The domain stays
/// transport-free; the runtime projects committed events onto the wire.
pub(all) enum BoardEvent {
  TaskCreated(id~ : BoardTaskId, at_ms~ : Int64)
  TaskUpdated(id~ : BoardTaskId, at_ms~ : Int64)
  DependenciesSet(
    id~ : BoardTaskId,
    dependencies~ : Array[BoardTaskId],
    at_ms~ : Int64
  )
  TaskModelChanged(id~ : BoardTaskId, model~ : ModelSelection?, at_ms~ : Int64)
  /// The ticket's curated review handoff was replaced (`Some`) or cleared
  /// (`None`). The report is durable data of the ticket, not attempt activity.
  ReviewReportSet(id~ : BoardTaskId, review~ : ReviewReport?, at_ms~ : Int64)
  TaskStageChanged(
    id~ : BoardTaskId,
    from~ : BoardStage,
    to~ : BoardStage,
    at_ms~ : Int64
  )
  TaskDeleted(id~ : BoardTaskId, at_ms~ : Int64)
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
  /// The one authoritative fact of an accepted graph expansion: the new
  /// task exists in stage Created and the durable expansion record binds
  /// the expansion identity, the lineage and the local_ref mapping. The
  /// digest is the normalized content binding, never raw proposal text.
  GraphExpanded(
    expansion~ : ExpansionId,
    tasks~ : Array[BoardTask],
    parent~ : BoardTaskId,
    workflow~ : String,
    mapping~ : Array[ExpansionMapping],
    digest~ : String,
    at_ms~ : Int64
  )
} derive(Eq, Debug)

///|
pub extend BoardEvent with Eq::{equal, not_equal}

///|
pub extend BoardEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Detach every mutable event payload at store, hook and caller boundaries.
pub fn BoardEvent::copy_detached(self : BoardEvent) -> BoardEvent {
  match self {
    DependenciesSet(id~, dependencies~, at_ms~) =>
      DependenciesSet(id~, dependencies=dependencies.copy(), at_ms~)
    TaskModelChanged(..) => self
    ReviewReportSet(id~, review~, at_ms~) =>
      ReviewReportSet(
        id~,
        review=match review {
          Some(report) => Some(report.copy_detached())
          None => None
        },
        at_ms~,
      )
    GraphExpanded(
      expansion~,
      tasks~,
      parent~,
      workflow~,
      mapping~,
      digest~,
      at_ms~
    ) =>
      GraphExpanded(
        expansion~,
        tasks=tasks.map(task => task.copy_detached()),
        parent~,
        workflow~,
        mapping=mapping.copy(),
        digest~,
        at_ms~,
      )
    _ => self
  }
}
