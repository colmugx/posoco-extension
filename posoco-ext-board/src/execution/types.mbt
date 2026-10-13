///|
/// Explicit trusted-host intent. Input is ephemeral and never journalled.
pub(all) struct BoardExecutionRequest {
  task_id : String
  attempt_id : String
  execution_id : String
  session_id : String
  input : String
  timeout_ms : Int32?
}

///|
pub(all) struct BoardExecutionRun {
  session_id : String
  run_id : String
  turn_id : String
} derive(Eq, Debug)

///|
/// Outcomes describe terminated execution, not task stage or review decision.
pub(all) enum BoardExecutionOutcome {
  Completed
  Failed
  Cancelled
  TimedOut
  Interrupted
} derive(Eq, Debug)

///|
pub(all) enum BoardExecutionPhase {
  Reserved
  Running
  Finished
  Settled
  Unresolved
} derive(Eq, Debug)

///|
/// Separate versioned journal metadata; never contains input or Agent output.
/// Unresolved records are evidence of ambiguity, not permission to execute again.
pub(all) struct BoardExecutionBinding {
  task_id : String
  attempt_id : String
  execution_id : String
  session_id : String
  run : BoardExecutionRun?
  phase : BoardExecutionPhase
  outcome : BoardExecutionOutcome?
} derive(Eq, Debug)

///|
pub(all) enum BoardExecutionError {
  NotReady
  Closed
  Busy
  InvalidRequest
  IneligibleAttempt
  DuplicateIdentity
  StoreUnavailable
  WrongExecution
} derive(Eq, Debug)

///|
/// One owner must exclusively own one journal. Errors, including ambiguous
/// writes, prohibit external execution or further automatic journal writes.
pub(open) trait BoardExecutionStore {
  async fn load(Self) -> Result[
    Array[BoardExecutionBinding],
    BoardExecutionError,
  ]
  async fn persist(Self, Array[BoardExecutionBinding]) -> Result[
    Unit,
    BoardExecutionError,
  ]
}

///|
/// A driver must own its run exclusively and await all execution cleanup before
/// returning. It calls the start gate with the actual identity before invoking
/// model/tools. A false gate must prevent those effects. Cancellation of `run`
/// must cancel/join that same owned execution, never an unrelated Agent.
pub(open) trait BoardExecutionAdapter {
  fn ready(Self) -> Bool
  async fn run(Self, BoardExecutionRequest, async (BoardExecutionRun) -> Bool) -> BoardExecutionOutcome
}
