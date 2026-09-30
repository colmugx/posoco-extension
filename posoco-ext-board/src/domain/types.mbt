///|
/// Board task stage. The legal moves between stages are defined once in
/// `stage_allowed`; execution-specific invariants attached to Running are
/// deferred to the S4 execution stage.
pub(all) enum BoardStage {
  Created
  Refining
  Ready
  Running
  Review
  Done
  Suspended
} derive(Eq, Debug)

///|
pub extend BoardStage with Eq::{equal, not_equal}

///|
pub extend BoardStage with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Ordered priority: Low < Normal < High < Critical. `rank` is the total
/// order used for deterministic task listing.
pub(all) enum BoardPriority {
  Low
  Normal
  High
  Critical
} derive(Eq, Debug)

///|
pub extend BoardPriority with Eq::{equal, not_equal}

///|
pub extend BoardPriority with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn BoardPriority::rank(self : BoardPriority) -> Int {
  match self {
    Low => 0
    Normal => 1
    High => 2
    Critical => 3
  }
}

///|
/// What kind of work one attempt performs.
pub(all) enum AttemptKind {
  Discuss
  Execute
  Review
} derive(Eq, Debug)

///|
pub extend AttemptKind with Eq::{equal, not_equal}

///|
pub extend AttemptKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Attempt status. Queued -> Running is admission; Running -> a terminal
/// outcome closes the attempt. The other combinations are invalid.
pub(all) enum AttemptStatus {
  Queued
  Running
  Succeeded
  Failed
  Cancelled
  Interrupted
} derive(Eq, Debug)

///|
pub extend AttemptStatus with Eq::{equal, not_equal}

///|
pub extend AttemptStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Terminal outcomes a caller may request for a running attempt.
pub(all) enum AttemptOutcome {
  Succeeded
  Failed
  Cancelled
  Interrupted
} derive(Eq, Debug)

///|
pub extend AttemptOutcome with Eq::{equal, not_equal}

///|
pub extend AttemptOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Review decision of a Review attempt. Pending is the implicit initial
/// value when the attempt starts running; only Approved or ChangesRequested
/// can be recorded.
pub(all) enum ReviewDecision {
  Pending
  Approved
  ChangesRequested
} derive(Eq, Debug)

///|
pub extend ReviewDecision with Eq::{equal, not_equal}

///|
pub extend ReviewDecision with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Product/business lifecycle record. Timestamps are explicit command
/// inputs; the domain owns no clock. `ready_since_ms` is set when the task
/// enters Ready and cleared when it leaves.
pub struct BoardTask {
  id : BoardTaskId
  title : String
  description : String
  stage : BoardStage
  priority : BoardPriority
  definition_of_done : Array[String]
  dependencies : Array[BoardTaskId]
  created_at_ms : Int64
  updated_at_ms : Int64
  ready_since_ms : Int64?
} derive(Eq, Debug)

///|
pub extend BoardTask with Eq::{equal, not_equal}

///|
pub extend BoardTask with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One unit of work performed against a task. Review attempts carry the
/// recorded review decision once started. `started_at_ms` is stamped when
/// the attempt leaves Queued and `finished_at_ms` when it reaches a
/// terminal outcome; each stays None until its event.
pub struct Attempt {
  id : AttemptId
  task_id : BoardTaskId
  kind : AttemptKind
  status : AttemptStatus
  review : ReviewDecision?
  created_at_ms : Int64
  started_at_ms : Int64?
  finished_at_ms : Int64?
  updated_at_ms : Int64
} derive(Eq, Debug)

///|
pub extend Attempt with Eq::{equal, not_equal}

///|
pub extend Attempt with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Detached point-in-time view of the whole board. Deep copies only; never
/// aliases committed state.
pub(all) struct BoardStateSnapshot {
  revision : Int64
  tasks : Array[BoardTask]
  attempts : Array[Attempt]
} derive(Eq, Debug)

///|
pub extend BoardStateSnapshot with Eq::{equal, not_equal}

///|
pub extend BoardStateSnapshot with @moonbitlang/core/debug.Debug::{to_repr}
