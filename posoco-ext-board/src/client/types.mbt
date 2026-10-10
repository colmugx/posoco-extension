///|
/// Client-owned wire stage, independent of domain transition rules.
pub(all) enum ClientBoardStage {
  Created
  Refining
  Ready
  Running
  Review
  Done
  Suspended
} derive(Eq)

///|
pub extend ClientBoardStage with Eq::{equal, not_equal}

///|
pub(all) enum ClientBoardPriority {
  Low
  Normal
  High
  Critical
} derive(Eq)

///|
pub extend ClientBoardPriority with Eq::{equal, not_equal}

///|
pub(all) enum ClientAttemptKind {
  Discuss
  Execute
  Review
} derive(Eq)

///|
pub extend ClientAttemptKind with Eq::{equal, not_equal}

///|
pub(all) enum ClientAttemptStatus {
  Queued
  Running
  Succeeded
  Failed
  Cancelled
  Interrupted
} derive(Eq)

///|
pub extend ClientAttemptStatus with Eq::{equal, not_equal}

///|
/// Terminal outcome a caller explicitly requests for a running attempt.
pub(all) enum ClientAttemptOutcome {
  Succeeded
  Failed
  Cancelled
  Interrupted
} derive(Eq)

///|
pub extend ClientAttemptOutcome with Eq::{equal, not_equal}

///|
/// Absence is Option::None, not an additional review enum case.
pub(all) enum ClientReviewDecision {
  Pending
  Approved
  ChangesRequested
} derive(Eq)

///|
pub extend ClientReviewDecision with Eq::{equal, not_equal}

///|
/// Decision a caller can explicitly record. Pending is deliberately not a
/// case: it is the implicit state when a review attempt starts running, so
/// it never appears in a wire command.
pub(all) enum ClientRecordableReviewDecision {
  Approved
  ChangesRequested
} derive(Eq)

///|
pub extend ClientRecordableReviewDecision with Eq::{equal, not_equal}

///|
/// Read-only record. Arrays returned by the replica are detached.
pub struct ClientBoardTask {
  id : String
  title : String
  description : String
  stage : ClientBoardStage
  priority : ClientBoardPriority
  definition_of_done : Array[String]
  dependencies : Array[String]
  created_at_ms : Int64
  updated_at_ms : Int64
  ready_since_ms : Int64?
} derive(Eq)

///|
pub extend ClientBoardTask with Eq::{equal, not_equal}

///|
pub struct ClientAttempt {
  id : String
  task_id : String
  kind : ClientAttemptKind
  status : ClientAttemptStatus
  review : ClientReviewDecision?
  created_at_ms : Int64
  started_at_ms : Int64?
  finished_at_ms : Int64?
  updated_at_ms : Int64
} derive(Eq)

///|
pub extend ClientAttempt with Eq::{equal, not_equal}

///|
/// Validated authoritative projection. The transport suffix is validated but
/// deliberately not retained or replayed into these records.
pub struct DecodedBoardSnapshot {
  revision : Int64
  last_seq : Int64
  tasks : Array[ClientBoardTask]
  attempts : Array[ClientAttempt]
} derive(Eq)

///|
pub extend DecodedBoardSnapshot with Eq::{equal, not_equal}

///|
pub(all) enum ClientError {
  InvalidData(String)
  UnsupportedProtocolVersion
} derive(Eq)

///|
pub extend ClientError with Eq::{equal, not_equal}

///|
/// A command settlement never projects optimistic state. NeedsSnapshot means
/// the old baseline was discarded. Terminal errors carry stable codes only.
pub(all) enum ApplyOutcome {
  Applied
  Duplicate
  CommandSettled(@protocol.BoardCommandResult)
  NeedsSnapshot(String)
  TerminalProtocolError(String)
} derive(Eq)

///|
pub extend ApplyOutcome with Eq::{equal, not_equal}

///|
/// Private mutable state; use the detached accessors and `copy` for
/// clone-on-update rendering, never shared collections.
pub struct BoardReplica {
  priv mut task_records : Array[ClientBoardTask]
  priv mut attempt_records : Array[ClientAttempt]
  priv mut board_revision : Int64
  priv mut sequence : Int64
  priv mut baseline : Bool
} derive(Eq)

///|
pub extend BoardReplica with Eq::{equal, not_equal}

///|
fn ClientBoardTask::copy_detached(self : ClientBoardTask) -> ClientBoardTask {
  {
    ..self,
    definition_of_done: self.definition_of_done.copy(),
    dependencies: self.dependencies.copy(),
  }
}
