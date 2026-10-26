///|
/// Typed board mutation. Every command carries the expected revision for
/// optimistic concurrency and explicit identifiers and timestamps; the
/// domain never reads a clock. All commands are validated first and either
/// produce a detached next state (revision + 1) or a typed rejection.
pub(all) enum BoardCommand {
  CreateTask(
    id~ : BoardTaskId,
    title~ : String,
    description~ : String,
    priority~ : BoardPriority,
    definition_of_done~ : Array[String],
    dependencies~ : Array[BoardTaskId],
    user_story~ : String,
    implementation_suggestions~ : String,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  UpdateTask(
    id~ : BoardTaskId,
    title~ : String?,
    description~ : String?,
    priority~ : BoardPriority?,
    definition_of_done~ : Array[String]?,
    user_story~ : String?,
    implementation_suggestions~ : String?,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  SetDependencies(
    id~ : BoardTaskId,
    dependencies~ : Array[BoardTaskId],
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  SetTaskModel(
    id~ : BoardTaskId,
    model~ : ModelSelection?,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  /// Replace the curated review handoff of one ticket with `Some`, or clear
  /// it with `None`. Only a ticket that is being worked on (Running) or is
  /// already under review (Review) carries a report.
  SetReviewReport(
    id~ : BoardTaskId,
    review~ : ReviewReport?,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  MoveTask(
    id~ : BoardTaskId,
    to~ : BoardStage,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  /// Remove a non-running task. Used when shaping replaces one oversized
  /// ticket with independently executable tickets.
  DeleteTask(id~ : BoardTaskId, at_ms~ : Int64, expected_revision~ : Int64)
  QueueAttempt(
    id~ : AttemptId,
    task~ : BoardTaskId,
    kind~ : AttemptKind,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  StartAttempt(id~ : AttemptId, at_ms~ : Int64, expected_revision~ : Int64)
  FinishAttempt(
    id~ : AttemptId,
    outcome~ : AttemptOutcome,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  RecordReview(
    id~ : AttemptId,
    decision~ : ReviewDecision,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  /// One reviewer decision that changes two records atomically: the attempt
  /// records ChangesRequested and the ticket stores the durable feedback and
  /// returns to Ready for another attempt.
  RequestChanges(
    id~ : AttemptId,
    feedback~ : String,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  /// S4E1 atomic additive graph expansion: all detached candidate tasks in
  /// stage Created, one durable expansion record and one GraphExpanded
  /// event. Existing tasks, edges and attempts are never touched.
  ExpandGraph(
    expansion~ : ExpansionId,
    candidates~ : Array[GraphTask],
    parent~ : BoardTaskId,
    workflow~ : String,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
} derive(Eq, Debug)

///|
pub extend BoardCommand with Eq::{equal, not_equal}

///|
pub extend BoardCommand with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn BoardCommand::expected_revision(self : BoardCommand) -> Int64 {
  match self {
    CreateTask(expected_revision~, ..)
    | UpdateTask(expected_revision~, ..)
    | SetDependencies(expected_revision~, ..)
    | SetTaskModel(expected_revision~, ..)
    | SetReviewReport(expected_revision~, ..)
    | MoveTask(expected_revision~, ..)
    | DeleteTask(expected_revision~, ..)
    | QueueAttempt(expected_revision~, ..)
    | StartAttempt(expected_revision~, ..)
    | FinishAttempt(expected_revision~, ..)
    | RecordReview(expected_revision~, ..)
    | RequestChanges(expected_revision~, ..)
    | ExpandGraph(expected_revision~, ..) => expected_revision
  }
}

///|
/// Detached copy of the command: every array payload is duplicated, so a
/// caller that keeps and mutates its arrays after submission cannot alter
/// what a later reader validates against. Scalar and id fields are
/// immutable and shared.
pub fn BoardCommand::copy_detached(self : BoardCommand) -> BoardCommand {
  match self {
    CreateTask(
      id~,
      title~,
      description~,
      priority~,
      definition_of_done~,
      dependencies~,
      user_story~,
      implementation_suggestions~,
      at_ms~,
      expected_revision~
    ) =>
      CreateTask(
        id~,
        title~,
        description~,
        priority~,
        definition_of_done=definition_of_done.copy(),
        dependencies=dependencies.copy(),
        user_story~,
        implementation_suggestions~,
        at_ms~,
        expected_revision~,
      )
    UpdateTask(
      id~,
      title~,
      description~,
      priority~,
      definition_of_done~,
      user_story~,
      implementation_suggestions~,
      at_ms~,
      expected_revision~
    ) =>
      match definition_of_done {
        Some(items) =>
          UpdateTask(
            id~,
            title~,
            description~,
            priority~,
            definition_of_done=Some(items.copy()),
            user_story~,
            implementation_suggestions~,
            at_ms~,
            expected_revision~,
          )
        None =>
          UpdateTask(
            id~,
            title~,
            description~,
            priority~,
            definition_of_done=None,
            user_story~,
            implementation_suggestions~,
            at_ms~,
            expected_revision~,
          )
      }
    SetDependencies(id~, dependencies~, at_ms~, expected_revision~) =>
      SetDependencies(
        id~,
        dependencies=dependencies.copy(),
        at_ms~,
        expected_revision~,
      )
    ExpandGraph(
      expansion~,
      candidates~,
      parent~,
      workflow~,
      at_ms~,
      expected_revision~
    ) =>
      ExpandGraph(
        expansion~,
        candidates=candidates.map(candidate => candidate.copy_detached()),
        parent~,
        workflow~,
        at_ms~,
        expected_revision~,
      )
    SetReviewReport(id~, review~, at_ms~, expected_revision~) =>
      SetReviewReport(
        id~,
        review=match review {
          Some(report) => Some(report.copy_detached())
          None => None
        },
        at_ms~,
        expected_revision~,
      )
    MoveTask(..)
    | DeleteTask(..)
    | SetTaskModel(..)
    | QueueAttempt(..)
    | StartAttempt(..)
    | FinishAttempt(..)
    | RecordReview(..)
    | RequestChanges(..) => self
  }
}
