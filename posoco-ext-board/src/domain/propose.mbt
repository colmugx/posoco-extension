///|
/// Namespace for the pure decision functions. Holds no data: propose turns
/// one (state, command) pair into either a detached successor state with
/// events, or a typed rejection. The input state and command arrays are
/// never mutated.
pub struct BoardDomain {}

///|
pub fn BoardDomain::BoardDomain() -> BoardDomain {
  BoardDomain::{ }
}

///|
/// Outcome of one proposed mutation. `next_state` is fully detached from
/// the input state; `events` are ordered facts about the transition.
pub(all) struct BoardProposal {
  next_state : BoardState
  events : Array[BoardEvent]
}

///|
/// Central stage FSM. One table, shared by every stage move; the S3A
/// baseline is Created->Refining/Suspended; Refining->Ready/Suspended;
/// Ready->Running/Refining/Suspended; Running->Review/Suspended;
/// Review->Done/Ready/Refining/Suspended; Done->Refining;
/// Suspended->Created/Refining/Ready.
fn stage_allowed(from : BoardStage, to : BoardStage) -> Bool {
  match (from, to) {
    (Created, Refining) | (Created, Suspended) => true
    (Refining, Ready) | (Refining, Suspended) => true
    (Ready, Running) | (Ready, Refining) | (Ready, Suspended) => true
    (Running, Review) | (Running, Suspended) => true
    (Review, Done)
    | (Review, Ready)
    | (Review, Refining)
    | (Review, Suspended) => true
    (Done, Refining) => true
    (Suspended, Created) | (Suspended, Refining) | (Suspended, Ready) => true
    _ => false
  }
}

///|
/// Attempt FSM baseline: Queued -> Running -> one terminal outcome.
/// Execution-specific coupling between Running attempts and task stages is
/// deferred to the S4 execution stage.
///
/// Review independence (S3A): the review decision and the attempt status
/// are orthogonal folds. Recording Approved/ChangesRequested never changes
/// the status, and finishing a Review attempt while its review is still
/// Pending is legal and leaves the decision untouched. Only the status FSM
/// gates recording: a terminal attempt can no longer be reviewed. S4 owns
/// any execution orchestration that ties decisions to outcomes.
fn attempt_status_allowed(from : AttemptStatus, to : AttemptStatus) -> Bool {
  match (from, to) {
    (Queued, Running) => true
    (Running, Succeeded)
    | (Running, Failed)
    | (Running, Cancelled)
    | (Running, Interrupted) => true
    _ => false
  }
}

///|
fn attempt_outcome_status(outcome : AttemptOutcome) -> AttemptStatus {
  match outcome {
    Succeeded => Succeeded
    Failed => Failed
    Cancelled => Cancelled
    Interrupted => Interrupted
  }
}

///|
/// Validation order inside every command: revision gate first, then input
/// sanity, then existence, then domain checks. Rejections never construct
/// a successor state.
pub fn BoardDomain::propose(
  state : BoardState,
  command : BoardCommand,
) -> Result[BoardProposal, BoardError] {
  let expected = command.expected_revision()
  let actual = state.revision()
  if expected != actual {
    return Err(RevisionConflict(expected~, actual~))
  }
  match command {
    CreateTask(
      id~,
      title~,
      description~,
      priority~,
      definition_of_done~,
      dependencies~,
      at_ms~,
      ..
    ) =>
      propose_create(
        state, id, title, description, priority, definition_of_done, dependencies,
        at_ms,
      )
    UpdateTask(
      id~,
      title~,
      description~,
      priority~,
      definition_of_done~,
      at_ms~,
      ..
    ) =>
      propose_update(
        state, id, title, description, priority, definition_of_done, at_ms,
      )
    SetDependencies(id~, dependencies~, at_ms~, ..) =>
      propose_set_dependencies(state, id, dependencies, at_ms)
    MoveTask(id~, to~, at_ms~, ..) => propose_move(state, id, to, at_ms)
    QueueAttempt(id~, task~, kind~, at_ms~, ..) =>
      propose_queue_attempt(state, id, task, kind, at_ms)
    StartAttempt(id~, at_ms~, ..) => propose_start_attempt(state, id, at_ms)
    FinishAttempt(id~, outcome~, at_ms~, ..) =>
      propose_finish_attempt(state, id, outcome, at_ms)
    RecordReview(id~, decision~, at_ms~, ..) =>
      propose_record_review(state, id, decision, at_ms)
  }
}

///|
fn invalid_time(at_ms : Int64) -> Bool {
  at_ms < 0L
}

///|
fn propose_create(
  state : BoardState,
  id : BoardTaskId,
  title : String,
  description : String,
  priority : BoardPriority,
  definition_of_done : Array[String],
  dependencies : Array[BoardTaskId],
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  if id.value == "" {
    return Err(InvalidInput(reason="task id must not be empty"))
  }
  if title == "" {
    return Err(InvalidInput(reason="title must not be empty"))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="created_at_ms must not be negative"))
  }
  for item in definition_of_done {
    if item == "" {
      return Err(
        InvalidInput(reason="definition_of_done items must not be empty"),
      )
    }
  }
  if state.task(id) is Some(_) {
    return Err(DuplicateTask(task=id))
  }
  match validate_dependencies(state, id, dependencies) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let next = state.clone_detached()
  let task : BoardTask = {
    id,
    title,
    description,
    stage: Created,
    priority,
    definition_of_done: definition_of_done.copy(),
    dependencies: dependencies.copy(),
    created_at_ms: at_ms,
    updated_at_ms: at_ms,
    ready_since_ms: None,
  }
  next.put_task(task)
  next.bump_revision()
  Ok({ next_state: next, events: [TaskCreated(id~, at_ms~)], })
}

///|
fn propose_update(
  state : BoardState,
  id : BoardTaskId,
  title : String?,
  description : String?,
  priority : BoardPriority?,
  definition_of_done : Array[String]?,
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  if id.value == "" {
    return Err(InvalidInput(reason="task id must not be empty"))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  match title {
    Some("") => return Err(InvalidInput(reason="title must not be empty"))
    _ => ()
  }
  match definition_of_done {
    Some(items) =>
      for item in items {
        if item == "" {
          return Err(
            InvalidInput(reason="definition_of_done items must not be empty"),
          )
        }
      }
    None => ()
  }
  if title is None &&
    description is None &&
    priority is None &&
    definition_of_done is None {
    return Err(InvalidInput(reason="update carries no changes"))
  }
  let task = match state.task(id) {
    Some(task) => task
    None => return Err(TaskMissing(task=id))
  }
  let next = state.clone_detached()
  let updated : BoardTask = {
    ..task,
    title: title.unwrap_or(task.title),
    description: description.unwrap_or(task.description),
    priority: priority.unwrap_or(task.priority),
    definition_of_done: match definition_of_done {
      Some(items) => items.copy()
      None => task.definition_of_done
    },
    updated_at_ms: at_ms,
  }
  next.put_task(updated)
  next.bump_revision()
  Ok({ next_state: next, events: [TaskUpdated(id~, at_ms~)], })
}

///|
fn propose_set_dependencies(
  state : BoardState,
  id : BoardTaskId,
  dependencies : Array[BoardTaskId],
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  if id.value == "" {
    return Err(InvalidInput(reason="task id must not be empty"))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  let task = match state.task(id) {
    Some(task) => task
    None => return Err(TaskMissing(task=id))
  }
  match validate_dependencies(state, id, dependencies) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let next = state.clone_detached()
  next.put_task({
    ..task,
    dependencies: dependencies.copy(),
    updated_at_ms: at_ms,
  })
  next.bump_revision()
  Ok({
    next_state: next,
    // The event copies the caller's array: events must stay detached from
    // command inputs just like the committed state.
    events: [DependenciesSet(id~, dependencies=dependencies.copy(), at_ms~)],
  })
}

///|
/// Entering Ready stamps `ready_since_ms` with the command time; leaving
/// Ready clears it. Ready does not require dependencies to be Done.
fn propose_move(
  state : BoardState,
  id : BoardTaskId,
  to : BoardStage,
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  if id.value == "" {
    return Err(InvalidInput(reason="task id must not be empty"))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  let task = match state.task(id) {
    Some(task) => task
    None => return Err(TaskMissing(task=id))
  }
  let from = task.stage
  if !stage_allowed(from, to) {
    return Err(InvalidTransition(from~, to~))
  }
  let ready_since_ms = if to is Ready {
    Some(at_ms)
  } else if from is Ready {
    None
  } else {
    task.ready_since_ms
  }
  let next = state.clone_detached()
  next.put_task({ ..task, stage: to, updated_at_ms: at_ms, ready_since_ms, })
  next.bump_revision()
  Ok({ next_state: next, events: [TaskStageChanged(id~, from~, to~, at_ms~)], })
}

///|
fn propose_queue_attempt(
  state : BoardState,
  id : AttemptId,
  task : BoardTaskId,
  kind : AttemptKind,
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  if id.value == "" {
    return Err(InvalidInput(reason="attempt id must not be empty"))
  }
  if task.value == "" {
    return Err(InvalidInput(reason="task id must not be empty"))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="created_at_ms must not be negative"))
  }
  if state.task(task) is None {
    return Err(TaskMissing(task~))
  }
  if state.attempt(id) is Some(_) {
    return Err(DuplicateAttempt(attempt=id))
  }
  let attempt : Attempt = {
    id,
    task_id: task,
    kind,
    status: Queued,
    review: None,
    created_at_ms: at_ms,
    started_at_ms: None,
    finished_at_ms: None,
    updated_at_ms: at_ms,
  }
  let next = state.clone_detached()
  next.put_attempt(attempt)
  next.bump_revision()
  Ok({
    next_state: next,
    events: [AttemptQueued(id~, task_id=task, kind~, at_ms~)],
  })
}

///|
fn propose_start_attempt(
  state : BoardState,
  id : AttemptId,
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  if id.value == "" {
    return Err(InvalidInput(reason="attempt id must not be empty"))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  let attempt = match state.attempt(id) {
    Some(attempt) => attempt
    None => return Err(AttemptMissing(attempt=id))
  }
  if !attempt_status_allowed(attempt.status, Running) {
    return Err(
      InvalidAttemptTransition(attempt=id, from=attempt.status, to=Running),
    )
  }
  let review = if attempt.kind is Review { Some(Pending) } else { None }
  let next = state.clone_detached()
  next.put_attempt({
    ..attempt,
    status: Running,
    review,
    started_at_ms: Some(at_ms),
    finished_at_ms: attempt.finished_at_ms,
    updated_at_ms: at_ms,
  })
  next.bump_revision()
  Ok({
    next_state: next,
    events: [AttemptStarted(id~, task_id=attempt.task_id, at_ms~)],
  })
}

///|
/// Finish a running attempt with one terminal outcome. The start stamp is
/// retained and the finish stamp set. A still-Pending review is left
/// as-is: finishing never fabricates a review decision (see the attempt
/// FSM's review-independence note). Recording afterwards is rejected
/// because only a Running attempt can be reviewed.
fn propose_finish_attempt(
  state : BoardState,
  id : AttemptId,
  outcome : AttemptOutcome,
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  if id.value == "" {
    return Err(InvalidInput(reason="attempt id must not be empty"))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  let attempt = match state.attempt(id) {
    Some(attempt) => attempt
    None => return Err(AttemptMissing(attempt=id))
  }
  let status = attempt_outcome_status(outcome)
  if !attempt_status_allowed(attempt.status, status) {
    return Err(
      InvalidAttemptTransition(attempt=id, from=attempt.status, to=status),
    )
  }
  let next = state.clone_detached()
  next.put_attempt({
    ..attempt,
    status,
    started_at_ms: attempt.started_at_ms,
    finished_at_ms: Some(at_ms),
    updated_at_ms: at_ms,
  })
  next.bump_revision()
  Ok({
    next_state: next,
    events: [AttemptFinished(id~, task_id=attempt.task_id, outcome~, at_ms~)],
  })
}

///|
/// Record one terminal review decision on a Running Review attempt whose
/// review is still Pending. The decision never changes the attempt status;
/// finishing stays a separate command (review independence, S3A).
fn propose_record_review(
  state : BoardState,
  id : AttemptId,
  decision : ReviewDecision,
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  if id.value == "" {
    return Err(InvalidInput(reason="attempt id must not be empty"))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  if decision is Pending {
    return Err(
      InvalidInput(reason="only Approved or ChangesRequested can be recorded"),
    )
  }
  let attempt = match state.attempt(id) {
    Some(attempt) => attempt
    None => return Err(AttemptMissing(attempt=id))
  }
  if !(attempt.kind is Review) {
    return Err(
      InvalidInput(reason="review decisions require an attempt of kind Review"),
    )
  }
  if !(attempt.status is Running) || !(attempt.review is Some(Pending)) {
    return Err(
      InvalidReviewTransition(
        attempt=id,
        current=attempt.review,
        requested=decision,
      ),
    )
  }
  let next = state.clone_detached()
  next.put_attempt({ ..attempt, review: Some(decision), updated_at_ms: at_ms, })
  next.bump_revision()
  Ok({
    next_state: next,
    events: [ReviewRecorded(id~, task_id=attempt.task_id, decision~, at_ms~)],
  })
}

///|
/// Existence, self-reference, duplicate-edge and cycle validation for one
/// candidate dependency list of `root`. Ready never requires dependencies
/// to be Done, so no stage checks happen here.
fn validate_dependencies(
  state : BoardState,
  root : BoardTaskId,
  dependencies : Array[BoardTaskId],
) -> Result[Unit, BoardError] {
  let seen : Set[BoardTaskId] = Set::from_array([])
  for dependency in dependencies {
    if dependency.value == "" {
      return Err(InvalidInput(reason="dependency id must not be empty"))
    }
    if dependency == root {
      return Err(SelfDependency(task=root))
    }
    if state.task_ref(dependency) is None {
      return Err(DependencyMissing(task=root, dependency~))
    }
    if seen.contains(dependency) {
      return Err(DuplicateDependency(task=root, dependency~))
    }
    seen.add(dependency)
  }
  match dependency_cycle(state, root, dependencies) {
    Some(cycle) => Err(DependencyCycle(cycle~))
    None => Ok(())
  }
}

///|
/// Follows dependency edges from `root` (with `root_deps` substituted for
/// its stored list) and returns the path from root to the dependency that
/// closes a cycle, or None when the graph stays acyclic. Deterministic:
/// edges are visited in declaration order.
fn dependency_cycle(
  state : BoardState,
  root : BoardTaskId,
  root_deps : Array[BoardTaskId],
) -> Array[BoardTaskId]? {
  fn neighbors(id : BoardTaskId) -> Array[BoardTaskId] {
    if id == root {
      root_deps
    } else {
      match state.task_ref(id) {
        Some(task) => task.dependencies
        None => []
      }
    }
  }
  let path : Array[BoardTaskId] = []
  let on_path : Set[BoardTaskId] = Set::from_array([])
  fn walk(node : BoardTaskId) -> Array[BoardTaskId]? {
    for dependency in neighbors(node) {
      if dependency == root {
        return Some(path.copy())
      }
      if on_path.contains(dependency) {
        continue
      }
      path.push(dependency)
      on_path.add(dependency)
      match walk(dependency) {
        Some(cycle) => return Some(cycle)
        None => {
          let _ = path.remove(path.length() - 1)
          on_path.remove(dependency)
        }
      }
    }
    None
  }
  walk(root)
}
