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
  Cancelled
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
pub struct ClientModelSelection {
  slot : String
  effort : String?
} derive(Eq)

///|
pub extend ClientModelSelection with Eq::{equal, not_equal}

///|
pub fn ClientModelSelection::ClientModelSelection(
  slot~ : String,
  effort~ : String? = None,
) -> ClientModelSelection {
  { slot, effort, }
}

///|
/// Client-owned evidence kind. Wire strings are stable
/// (`command`, `test`, `manual`, `artifact`).
pub(all) enum ClientReviewEvidenceKind {
  Command
  Test
  Manual
  Artifact
} derive(Eq)

///|
pub extend ClientReviewEvidenceKind with Eq::{equal, not_equal}

///|
pub(all) enum ClientReviewEvidenceResult {
  Passed
  Failed
  NotRun
  Unknown
} derive(Eq)

///|
pub extend ClientReviewEvidenceResult with Eq::{equal, not_equal}

///|
pub(all) enum ClientReviewArtifactKind {
  File
  Diff
  Log
  Screenshot
  Url
} derive(Eq)

///|
pub extend ClientReviewArtifactKind with Eq::{equal, not_equal}

///|
/// Read-only record. Arrays returned by the replica are detached.
pub struct ClientReviewEvidence {
  kind : ClientReviewEvidenceKind
  label : String
  result : ClientReviewEvidenceResult
  detail : String
} derive(Eq)

///|
pub extend ClientReviewEvidence with Eq::{equal, not_equal}

///|
pub fn ClientReviewEvidence::ClientReviewEvidence(
  kind~ : ClientReviewEvidenceKind,
  label~ : String,
  result~ : ClientReviewEvidenceResult,
  detail~ : String,
) -> ClientReviewEvidence {
  { kind, label, result, detail, }
}

///|
/// Read-only record. Arrays returned by the replica are detached.
pub struct ClientReviewArtifact {
  kind : ClientReviewArtifactKind
  label : String
  uri_or_digest : String
} derive(Eq)

///|
pub extend ClientReviewArtifact with Eq::{equal, not_equal}

///|
pub fn ClientReviewArtifact::ClientReviewArtifact(
  kind~ : ClientReviewArtifactKind,
  label~ : String,
  uri_or_digest~ : String,
) -> ClientReviewArtifact {
  { kind, label, uri_or_digest, }
}

///|
/// Read-only record. Arrays returned by the replica are detached.
pub struct ClientReviewReport {
  outcome : String
  summary : String
  changes : Array[String]
  verification : Array[ClientReviewEvidence]
  risks : Array[String]
  notes : Array[String]
  open_questions : Array[String]
  artifacts : Array[ClientReviewArtifact]
} derive(Eq)

///|
pub extend ClientReviewReport with Eq::{equal, not_equal}

///|
pub fn ClientReviewReport::ClientReviewReport(
  outcome~ : String,
  summary~ : String,
  changes~ : Array[String],
  verification~ : Array[ClientReviewEvidence],
  risks~ : Array[String],
  notes~ : Array[String],
  open_questions~ : Array[String],
  artifacts~ : Array[ClientReviewArtifact],
) -> ClientReviewReport {
  {
    outcome,
    summary,
    changes: changes.copy(),
    verification: verification.copy(),
    risks: risks.copy(),
    notes: notes.copy(),
    open_questions: open_questions.copy(),
    artifacts: artifacts.copy(),
  }
}

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
  model : ClientModelSelection?
  review : ClientReviewReport?
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
    review: match self.review {
      Some(report) => Some(report.copy_detached())
      None => None
    },
  }
}

///|
fn ClientReviewReport::copy_detached(
  self : ClientReviewReport,
) -> ClientReviewReport {
  {
    outcome: self.outcome,
    summary: self.summary,
    changes: self.changes.copy(),
    verification: self.verification.copy(),
    risks: self.risks.copy(),
    notes: self.notes.copy(),
    open_questions: self.open_questions.copy(),
    artifacts: self.artifacts.copy(),
  }
}
