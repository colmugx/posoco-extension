///|
/// Decoder output only. Local references and existing Board IDs are disjoint.
pub(all) struct DraftExpansion {
  proposal_id : String
  parent_task_id : String
  base_revision : Int64
  tasks : Array[DraftTask]
} derive(Eq, Debug)

///|
pub extend DraftExpansion with Eq::{equal, not_equal}

///|
pub extend DraftExpansion with @debug.Debug::{to_repr}

///|
pub(all) struct DraftTask {
  key : String
  title : String
  description : String
  priority : @domain.BoardPriority
  definition_of_done : Array[String]
  depends_on : Array[ExpansionRefResolution]
} derive(Eq, Debug)

///|
pub extend DraftTask with Eq::{equal, not_equal}

///|
pub extend DraftTask with @debug.Debug::{to_repr}

///|
pub(all) enum ExpansionRefResolution {
  NewTask(key~ : String)
  ExistingTask(id~ : @domain.BoardTaskId)
} derive(Eq, Debug)

///|
pub extend ExpansionRefResolution with Eq::{equal, not_equal}

///|
pub extend ExpansionRefResolution with @debug.Debug::{to_repr}

///|
pub(all) enum ExpansionDecodeError {
  MalformedJson(offset~ : Int32, reason~ : String)
  /// Lone surrogates and unescaped control characters, with the code-unit
  /// offset where they were seen.
  UnsupportedEncoding(offset~ : Int32, reason~ : String)
  InvalidNumber(offset~ : Int32, reason~ : String)
  DuplicateField(path~ : String, field~ : String)
  UnknownField(path~ : String, field~ : String)
  MissingField(path~ : String, field~ : String)
  TypeMismatch(path~ : String, expected~ : String)
  /// The `version` field exists but is not the exact accepted literal.
  InvalidVersion(found~ : String)
  InvalidPriority(path~ : String, value~ : String)
  /// Blank, whitespace-carrying or otherwise unusable string content.
  InvalidString(path~ : String, reason~ : String)
  ExceedsLimit(path~ : String, limit~ : String)
} derive(Eq, Debug)

///|
pub extend ExpansionDecodeError with Eq::{equal, not_equal}

///|
pub extend ExpansionDecodeError with @debug.Debug::{to_repr}

///|
pub(all) enum ExpansionPhase {
  Empty
  Validated
  AwaitingApproval
  Approved
  CommitRequested
  Committed
  Rejected
  Conflict
  Uncertain
} derive(Eq, Debug)

///|
pub extend ExpansionPhase with Eq::{equal, not_equal}

///|
pub extend ExpansionPhase with @debug.Debug::{to_repr}

///|
pub(all) enum ExpansionError {
  DefaultDenied
  InvalidAuthorization(String)
  Expired
  Busy
  InvalidPhase
  DecodeFailed(ExpansionDecodeError)
  InvalidProposal(String)
  PolicyBudgetExceeded(String)
  DomainRejected(@domain.BoardError)
  Backend(@coordinator.BoardCoordinatorError)
  SourceFailed(DynamicPlanSourceError)
  StalePreview
  ApprovalMismatch
  HostDenied
  AllocationFailed
  DuplicateProposal
  DigestConflict
} derive(Eq, Debug)

///|
pub extend ExpansionError with Eq::{equal, not_equal}

///|
pub extend ExpansionError with @debug.Debug::{to_repr}
