///|
/// Client-owned wire stage, independent of domain transition rules.
#derive(Eq)
pub(all) enum ClientBoardStage {
  Created
  Refining
  Ready
  Running
  Verification
  Review
  Done
  Suspended
  Cancelled
}

///|
pub extend ClientBoardStage with Eq::{equal, not_equal}

///|
#derive(Eq)
pub(all) enum ClientBoardPriority {
  Low
  Normal
  High
  Critical
}

///|
pub extend ClientBoardPriority with Eq::{equal, not_equal}

///|
#derive(Eq)
pub(all) enum ClientTeamRole {
  PO
  SM
  RD
  SET
  TE
}

///|
pub extend ClientTeamRole with Eq::{equal, not_equal}

///|
#derive(Eq)
pub struct ClientTeamAssignment {
  role : ClientTeamRole
  member_id : String
}

///|
pub extend ClientTeamAssignment with Eq::{equal, not_equal}

///|
#derive(Eq)
pub(all) enum ClientAttemptKind {
  Discuss
  Execute
  Review
}

///|
pub extend ClientAttemptKind with Eq::{equal, not_equal}

///|
#derive(Eq)
pub(all) enum ClientAttemptStatus {
  Queued
  Running
  Succeeded
  Failed
  Cancelled
  Interrupted
}

///|
pub extend ClientAttemptStatus with Eq::{equal, not_equal}

///|
/// Terminal outcome a caller explicitly requests for a running attempt.
#derive(Eq)
pub(all) enum ClientAttemptOutcome {
  Succeeded
  Failed
  Cancelled
  Interrupted
}

///|
pub extend ClientAttemptOutcome with Eq::{equal, not_equal}

///|
/// Absence is Option::None, not an additional review enum case.
#derive(Eq)
pub(all) enum ClientReviewDecision {
  Pending
  Approved
  ChangesRequested
}

///|
pub extend ClientReviewDecision with Eq::{equal, not_equal}

///|
/// Decision a caller can explicitly record. Pending is deliberately not a
/// case: it is the implicit state when a review attempt starts running, so
/// it never appears in a wire command.
#derive(Eq)
pub(all) enum ClientRecordableReviewDecision {
  Approved
  ChangesRequested
}

///|
pub extend ClientRecordableReviewDecision with Eq::{equal, not_equal}

///|
/// Read-only record. Arrays returned by the replica are detached.
#derive(Eq)
pub struct ClientModelSelection {
  slot : String
  effort : String?
}

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
#derive(Eq)
pub(all) enum ClientReviewEvidenceKind {
  Command
  Test
  Manual
  Artifact
}

///|
pub extend ClientReviewEvidenceKind with Eq::{equal, not_equal}

///|
#derive(Eq)
pub(all) enum ClientReviewEvidenceResult {
  Passed
  Failed
  NotRun
  Unknown
}

///|
pub extend ClientReviewEvidenceResult with Eq::{equal, not_equal}

///|
#derive(Eq)
pub(all) enum ClientReviewArtifactKind {
  File
  Diff
  Log
  Screenshot
  Url
}

///|
pub extend ClientReviewArtifactKind with Eq::{equal, not_equal}

///|
/// Read-only record. Arrays returned by the replica are detached.
#derive(Eq)
pub struct ClientReviewEvidence {
  kind : ClientReviewEvidenceKind
  label : String
  result : ClientReviewEvidenceResult
  detail : String
}

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
#derive(Eq)
pub struct ClientReviewArtifact {
  kind : ClientReviewArtifactKind
  label : String
  uri_or_digest : String
}

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
#derive(Eq)
pub struct ClientReviewReport {
  outcome : String
  summary : String
  changes : Array[String]
  verification : Array[ClientReviewEvidence]
  risks : Array[String]
  notes : Array[String]
  open_questions : Array[String]
  artifacts : Array[ClientReviewArtifact]
}

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
#derive(Eq)
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
  user_story : String
  implementation_suggestions : String
  assignments : Array[ClientTeamAssignment]
  required_roles : Array[ClientTeamRole]
  model : ClientModelSelection?
  review : ClientReviewReport?
  /// Durable reviewer feedback of the latest request-changes decision;
  /// `None` when no decision ever requested changes.
  review_feedback : String?
}

///|
pub extend ClientBoardTask with Eq::{equal, not_equal}

///|
#derive(Eq)
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
}

///|
pub extend ClientAttempt with Eq::{equal, not_equal}

///|
/// Validated authoritative projection. The transport suffix is validated but
/// deliberately not retained or replayed into these records.
#derive(Eq)
pub struct DecodedBoardSnapshot {
  revision : Int64
  last_seq : Int64
  tasks : Array[ClientBoardTask]
  attempts : Array[ClientAttempt]
}

///|
pub extend DecodedBoardSnapshot with Eq::{equal, not_equal}

///|
#derive(Eq)
pub(all) enum ClientError {
  InvalidData(String)
  UnsupportedProtocolVersion
}

///|
pub extend ClientError with Eq::{equal, not_equal}

///|
/// A command settlement never projects optimistic state. NeedsSnapshot means
/// the old baseline was discarded. Terminal errors carry stable codes only.
#derive(Eq)
pub(all) enum ApplyOutcome {
  Applied
  Duplicate
  CommandSettled(@protocol.BoardCommandResult)
  NeedsSnapshot(String)
  TerminalProtocolError(String)
}

///|
pub extend ApplyOutcome with Eq::{equal, not_equal}

///|
/// Private mutable state; use the detached accessors and `copy` for
/// clone-on-update rendering, never shared collections.
#derive(Eq)
pub struct BoardReplica {
  priv mut task_records : Array[ClientBoardTask]
  priv mut attempt_records : Array[ClientAttempt]
  priv mut board_revision : Int64
  priv mut sequence : Int64
  priv mut baseline : Bool
}

///|
pub extend BoardReplica with Eq::{equal, not_equal}

///|
fn ClientBoardTask::copy_detached(self : ClientBoardTask) -> ClientBoardTask {
  {
    ..self,
    definition_of_done: self.definition_of_done.copy(),
    dependencies: self.dependencies.copy(),
    assignments: self.assignments.copy(),
    required_roles: self.required_roles.copy(),
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
