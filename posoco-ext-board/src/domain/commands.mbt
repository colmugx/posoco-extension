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
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  UpdateTask(
    id~ : BoardTaskId,
    title~ : String?,
    description~ : String?,
    priority~ : BoardPriority?,
    definition_of_done~ : Array[String]?,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  SetDependencies(
    id~ : BoardTaskId,
    dependencies~ : Array[BoardTaskId],
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
  MoveTask(
    id~ : BoardTaskId,
    to~ : BoardStage,
    at_ms~ : Int64,
    expected_revision~ : Int64
  )
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
    | MoveTask(expected_revision~, ..)
    | QueueAttempt(expected_revision~, ..)
    | StartAttempt(expected_revision~, ..)
    | FinishAttempt(expected_revision~, ..)
    | RecordReview(expected_revision~, ..) => expected_revision
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
        at_ms~,
        expected_revision~,
      )
    UpdateTask(
      id~,
      title~,
      description~,
      priority~,
      definition_of_done~,
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
    MoveTask(..)
    | QueueAttempt(..)
    | StartAttempt(..)
    | FinishAttempt(..)
    | RecordReview(..) => self
  }
}
