///|
/// Post-commit execution outlook. After an expansion is committed, the
/// generated tasks exist as **Created** tasks with **no** attempts: they are
/// not execution scope, and nothing in this package moves a stage or queues
/// an Attempt. The classification below reuses the existing S4B pure planner
/// (`plan_execution`) over a fresh authoritative snapshot supplied by the
/// trusted host, so the reported outlook is exactly what S4B would plan.

///|
pub(all) enum GeneratedTaskOutlookClass {
  /// The task leads the current S4B plan as eligible.
  Eligible
  /// The S4B planner reports structured block reasons.
  Blocked(reasons~ : Array[@orchestration.ExecutionBlockReason])
  /// The task is not part of the plan's rows (e.g. the snapshot predates the
  /// commit or the planner scoped it out); never assumed admissible.
  OutOfScope
} derive(Eq, Debug)

///|
pub extend GeneratedTaskOutlookClass with Eq::{equal, not_equal}

///|
pub extend GeneratedTaskOutlookClass with @debug.Debug::{to_repr}

///|
pub(all) struct GeneratedTaskOutlook {
  key : String
  task_id : String
  outside_workflow_task_scope : Bool
  stage_created : Bool
  queued_execute_attempts : Int32
  class : GeneratedTaskOutlookClass
  /// True when the committed task is not in the expected post-commit shape
  /// (missing, not Created, or carrying queued Execute attempts). Report
  /// only: nothing is corrected or executed automatically.
  unexpected_state : Bool
} derive(Eq, Debug)

///|
pub extend GeneratedTaskOutlook with Eq::{equal, not_equal}

///|
pub extend GeneratedTaskOutlook with @debug.Debug::{to_repr}

///|
/// Classify committed generated tasks against a fresh authoritative snapshot
/// with the existing S4B planner. Newly committed tasks are expected to be
/// `Created` with no queued attempts, hence blocked until a host explicitly
/// readies and queues them — that is the contract, not a failure.
pub fn expansion_execution_outlook(
  keys~ : Array[String],
  task_ids~ : Array[String],
  snapshot~ : @domain.BoardStateSnapshot,
  workflow_task_scope~ : Array[String] = [],
  policy~ : @orchestration.ExecutionPolicy = @orchestration.ExecutionPolicy(),
) -> Array[GeneratedTaskOutlook] {
  let plan = @orchestration.plan_execution(snapshot, policy, [])
  let tasks : Map[String, @domain.BoardTask] = Map([])
  for task in snapshot.tasks {
    tasks[task.id.value] = task
  }
  let outlook : Array[GeneratedTaskOutlook] = []
  let count = if keys.length() < task_ids.length() {
    keys.length()
  } else {
    task_ids.length()
  }
  for index in 0..<count {
    let key = keys[index]
    let task_id = task_ids[index]
    let task = tasks.get(task_id)
    let attempts = snapshot.attempts.filter(attempt => {
      attempt.task_id.value == task_id &&
      attempt.kind is @domain.Execute &&
      attempt.status is @domain.Queued
    })
    let class : GeneratedTaskOutlookClass = if plan.eligible.any(candidate => {
        candidate.task_id == task_id
      }) {
      Eligible
    } else if plan.blocked.any(row => row.task_id == task_id) {
      let reasons = plan.blocked
        .filter(row => row.task_id == task_id)
        .iter()
        .flat_map(row => row.reasons.iter())
        .collect()
      Blocked(reasons~)
    } else {
      OutOfScope
    }
    outlook.push({
      key,
      task_id,
      outside_workflow_task_scope: !workflow_task_scope.contains(task_id),
      stage_created: task
      .map(task => task.stage is @domain.Created)
      .unwrap_or(false),
      queued_execute_attempts: attempts.length(),
      class,
      unexpected_state: task
      .map(task => !(task.stage is @domain.Created))
      .unwrap_or(true) ||
      !attempts.is_empty(),
    })
  }
  outlook
}
