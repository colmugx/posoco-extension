///|
/// Typed domain rejection. Every failed propose leaves the state untouched.
pub(all) enum BoardError {
  /// The command's optimistic-concurrency expectation lost the race.
  RevisionConflict(expected~ : Int64, actual~ : Int64)
  TaskMissing(task~ : BoardTaskId)
  AttemptMissing(attempt~ : AttemptId)
  /// Stage move rejected by the central FSM.
  InvalidTransition(from~ : BoardStage, to~ : BoardStage)
  /// Attempt status move rejected by the attempt FSM.
  InvalidAttemptTransition(
    attempt~ : AttemptId,
    from~ : AttemptStatus,
    to~ : AttemptStatus
  )
  /// Review decision rejected given the attempt's current review state.
  InvalidReviewTransition(
    attempt~ : AttemptId,
    current~ : ReviewDecision?,
    requested~ : ReviewDecision
  )
  /// A referenced dependency task does not exist.
  DependencyMissing(task~ : BoardTaskId, dependency~ : BoardTaskId)
  /// A task may not depend on itself.
  SelfDependency(task~ : BoardTaskId)
  /// The same dependency edge was declared twice.
  DuplicateDependency(task~ : BoardTaskId, dependency~ : BoardTaskId)
  // The path lists every task between the command's task and the
  // dependency that closes the cycle, in DFS order.
  DependencyCycle(cycle~ : Array[BoardTaskId])
  /// CreateTask with an id that is already on the board.
  DuplicateTask(task~ : BoardTaskId)
  /// QueueAttempt with an id that already exists.
  DuplicateAttempt(attempt~ : AttemptId)
  /// Structurally malformed input: empty identifiers, negative timestamps,
  /// empty titles or DoD items, no-op updates, unrecordable decisions.
  InvalidInput(reason~ : String)
} derive(Eq, Debug)

///|
pub extend BoardError with Eq::{equal, not_equal}

///|
pub extend BoardError with @moonbitlang/core/debug.Debug::{to_repr}
