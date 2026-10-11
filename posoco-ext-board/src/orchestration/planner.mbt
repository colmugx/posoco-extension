///|
fn task_order(a : @domain.BoardTask, b : @domain.BoardTask) -> Int {
  let priority = b.priority.rank() - a.priority.rank()
  if priority != 0 {
    priority
  } else if a.created_at_ms < b.created_at_ms {
    -1
  } else if a.created_at_ms > b.created_at_ms {
    1
  } else {
    a.id.value.compare(b.id.value)
  }
}

///|
fn attempt_order(a : @domain.Attempt, b : @domain.Attempt) -> Int {
  if a.created_at_ms < b.created_at_ms {
    -1
  } else if a.created_at_ms > b.created_at_ms {
    1
  } else {
    a.id.value.compare(b.id.value)
  }
}

///|
/// Pure policy evaluation: priority descending, creation time ascending, ID
/// ascending; oldest queued Execute Attempt then Attempt ID. Multiple queued
/// Attempts do not create parallel slots. Missing/conflicting input metadata
/// fails closed. The snapshot and all nested arrays are left untouched.
///
/// ```mbt check
/// test {
///   let plan = @orchestration.plan_execution(
///     { revision: 0L, tasks: [], attempts: [], },
///     @orchestration.ExecutionPolicy(enabled=true),
///     [],
///   )
///   assert_eq(plan.revision, 0L)
///   assert_eq(plan.eligible.length(), 0)
/// }
/// ```
pub fn plan_execution(
  snapshot : @domain.BoardStateSnapshot,
  policy : ExecutionPolicy,
  inputs : Array[ExecutionInputAvailability],
) -> ExecutionPlan {
  let tasks = snapshot.tasks.copy()
  tasks.sort_by(task_order)
  let eligible : Array[ExecutionCandidate] = []
  let blocked : Array[BlockedExecution] = []
  for task in tasks {
    let reasons : Array[ExecutionBlockReason] = []
    if !policy.enabled {
      reasons.push(AdmissionDisabled)
    }
    if !policy.stages_.contains(task.stage) {
      reasons.push(TaskStageIneligible)
    }
    let dependencies = task.dependencies.map(id => id.value)
    dependencies.sort()
    for dependency_id in dependencies {
      match snapshot.tasks.search_by(task => task.id.value == dependency_id) {
        None => reasons.push(MissingDependency(dependency_id))
        Some(index) if snapshot.tasks[index].stage != @domain.Done =>
          reasons.push(DependencyNotDone(dependency_id))
        _ => ()
      }
    }
    let attempts = snapshot.attempts.filter(attempt => {
      attempt.task_id == task.id &&
      attempt.kind is @domain.Execute &&
      attempt.status is @domain.Queued
    })
    attempts.sort_by(attempt_order)
    let attempt_id = match attempts.get(0) {
      None => {
        reasons.push(NoQueuedExecuteAttempt)
        None
      }
      Some(attempt) => {
        let metadata = inputs.filter(input => {
          input.task_id == task.id.value && input.attempt_id == attempt.id.value
        })
        if metadata.any(input => input.status is Denied) {
          reasons.push(AuthorizationDenied)
        } else if metadata.length() != 1 || metadata[0].status != Available {
          reasons.push(MissingExecutionInput)
        }
        Some(attempt.id.value)
      }
    }
    match attempt_id {
      Some(attempt_id) if reasons.is_empty() =>
        eligible.push({ task_id: task.id.value, attempt_id, })
      _ => blocked.push({ task_id: task.id.value, attempt_id, reasons, })
    }
  }
  { revision: snapshot.revision, policy_id: policy.id, eligible, blocked, }
}
