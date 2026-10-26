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
/// Central stage FSM. One table, shared by every stage move; the V2 flow is
/// Created->Refining; Refining->Ready; Ready->Running; Running->Verification;
/// Verification->Review; Review->Done. Every non-terminal stage may suspend
/// or cancel; Cancelled is terminal and Done cannot be cancelled.
fn stage_allowed(from : BoardStage, to : BoardStage) -> Bool {
  match (from, to) {
    (Created, Refining) | (Created, Suspended) | (Created, Cancelled) => true
    (Refining, Ready) | (Refining, Suspended) | (Refining, Cancelled) => true
    (Ready, Running)
    | (Ready, Refining)
    | (Ready, Suspended)
    | (Ready, Cancelled) => true
    (Running, Verification)
    | (Running, Review)
    | (Running, Suspended)
    | (Running, Cancelled) => true
    (Verification, Review)
    | (Verification, Ready)
    | (Verification, Refining)
    | (Verification, Suspended)
    | (Verification, Cancelled) => true
    (Review, Done)
    | (Review, Ready)
    | (Review, Refining)
    | (Review, Suspended)
    | (Review, Cancelled) => true
    (Done, Refining) => true
    (Suspended, Created)
    | (Suspended, Refining)
    | (Suspended, Ready)
    | (Suspended, Cancelled) => true
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
      user_story~,
      implementation_suggestions~,
      at_ms~,
      ..
    ) =>
      propose_create(
        state, id, title, description, priority, definition_of_done, dependencies,
        user_story, implementation_suggestions, at_ms,
      )
    UpdateTask(
      id~,
      title~,
      description~,
      priority~,
      definition_of_done~,
      user_story~,
      implementation_suggestions~,
      at_ms~,
      ..
    ) =>
      propose_update(
        state, id, title, description, priority, definition_of_done, user_story,
        implementation_suggestions, at_ms,
      )
    SetDependencies(id~, dependencies~, at_ms~, ..) =>
      propose_set_dependencies(state, id, dependencies, at_ms)
    SetTaskModel(id~, model~, at_ms~, ..) =>
      propose_set_model(state, id, model, at_ms)
    SetReviewReport(id~, review~, at_ms~, ..) =>
      propose_set_review_report(state, id, review, at_ms)
    MoveTask(id~, to~, at_ms~, ..) => propose_move(state, id, to, at_ms)
    DeleteTask(id~, at_ms~, ..) => propose_delete(state, id, at_ms)
    QueueAttempt(id~, task~, kind~, at_ms~, ..) =>
      propose_queue_attempt(state, id, task, kind, at_ms)
    StartAttempt(id~, at_ms~, ..) => propose_start_attempt(state, id, at_ms)
    FinishAttempt(id~, outcome~, at_ms~, ..) =>
      propose_finish_attempt(state, id, outcome, at_ms)
    RecordReview(id~, decision~, at_ms~, ..) =>
      propose_record_review(state, id, decision, at_ms)
    RequestChanges(id~, feedback~, at_ms~, ..) =>
      propose_request_changes(state, id, feedback, at_ms)
    ExpandGraph(expansion~, candidates~, parent~, workflow~, at_ms~, ..) =>
      propose_expand_graph(
        state, expansion, candidates, parent, workflow, at_ms,
      )
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
  user_story : String,
  implementation_suggestions : String,
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
    user_story,
    implementation_suggestions,
    model: None,
    review: None,
    review_feedback: None,
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
  user_story : String?,
  implementation_suggestions : String?,
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
    definition_of_done is None &&
    user_story is None &&
    implementation_suggestions is None {
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
    user_story: user_story.unwrap_or(task.user_story),
    implementation_suggestions: implementation_suggestions.unwrap_or(
      task.implementation_suggestions,
    ),
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
/// Pin or clear the work item's model. The domain validates shape only; the
/// host validates the slot against the current modelport catalog.
fn propose_set_model(
  state : BoardState,
  id : BoardTaskId,
  model : ModelSelection?,
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
  match task.stage {
    Done | Cancelled =>
      return Err(
        InvalidInput(reason="a terminal ticket cannot change its model"),
      )
    _ => ()
  }
  match model {
    Some(selection) => {
      if selection.slot.trim().is_empty() {
        return Err(InvalidInput(reason="model slot must not be empty"))
      }
      match selection.effort {
        Some(effort) if effort.trim().is_empty() =>
          return Err(InvalidInput(reason="model effort must not be empty"))
        _ => ()
      }
    }
    None => ()
  }
  let next = state.clone_detached()
  next.put_task({ ..task, model, updated_at_ms: at_ms, })
  next.bump_revision()
  Ok({ next_state: next, events: [TaskModelChanged(id~, model~, at_ms~)], })
}

///|
/// Structural validation of one curated review report: the handoff is only
/// useful when it says what is now true (`outcome`), what it means
/// (`summary`) and which evidence/artifacts it references by name. Free-form
/// text stays free-form; only the identifying fields must be present.
fn validate_review_report(report : ReviewReport) -> Result[Unit, BoardError] {
  if report.outcome.is_empty() {
    return Err(InvalidInput(reason="review outcome must not be empty"))
  }
  if report.summary.is_empty() {
    return Err(InvalidInput(reason="review summary must not be empty"))
  }
  for evidence in report.verification {
    if evidence.label.is_empty() {
      return Err(InvalidInput(reason="review evidence label must not be empty"))
    }
  }
  for artifact in report.artifacts {
    if artifact.label.is_empty() {
      return Err(InvalidInput(reason="review artifact label must not be empty"))
    }
    if artifact.uri_or_digest.is_empty() {
      return Err(
        InvalidInput(reason="review artifact uri_or_digest must not be empty"),
      )
    }
  }
  Ok(())
}

///|
/// Replace or clear the ticket's curated review handoff. Only a ticket that
/// is being worked on or is under review carries a report: a report is the
/// evidence of work, so Created/Refining/Ready tickets (nothing produced yet)
/// and terminal ones (Done/Cancelled) cannot set or clear it. `None` is an
/// explicit clear, never a fallback for a rejected report.
fn propose_set_review_report(
  state : BoardState,
  id : BoardTaskId,
  review : ReviewReport?,
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  let task = match state.task(id) {
    Some(task) => task
    None => return Err(TaskMissing(task=id))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  match task.stage {
    Running | Review => ()
    _ =>
      return Err(
        InvalidInput(
          reason="a review report requires a Running or Review ticket",
        ),
      )
  }
  let detached = match review {
    Some(report) => {
      match validate_review_report(report) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      Some(report.copy_detached())
    }
    None => None
  }
  let next = state.clone_detached()
  next.put_task({ ..task, review: detached, updated_at_ms: at_ms, })
  next.bump_revision()
  Ok({
    next_state: next,
    events: [
      ReviewReportSet(
        id~,
        review=match detached {
          Some(report) => Some(report.copy_detached())
          None => None
        },
        at_ms~,
      ),
    ],
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
/// Delete is deliberately narrower than move: a ticket that is already
/// running, under review, done, or suspended is not removed. Shaping uses
/// this only for a source ticket it has just replaced with Ready children.
fn propose_delete(
  state : BoardState,
  id : BoardTaskId,
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
  match task.stage {
    Created | Refining | Ready => ()
    _ =>
      return Err(
        InvalidInput(
          reason="only Backlog, Shaping, or Ready tickets can be deleted",
        ),
      )
  }
  for other in state.tasks() {
    if other.dependencies.contains(id) {
      return Err(
        InvalidInput(
          reason="task is still a dependency of another task ('" +
            other.id.value +
            "')",
        ),
      )
    }
  }
  for attempt in state.attempts() {
    if attempt.task_id == id {
      return Err(
        InvalidInput(
          reason="task still has an attempt ('" + attempt.id.value + "')",
        ),
      )
    }
  }
  let next = state.clone_detached()
  next.remove_task(id)
  next.bump_revision()
  Ok({ next_state: next, events: [TaskDeleted(id~, at_ms~)], })
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
/// Reviewer feedback is durable text, so it is normalized once at the
/// boundary: the decision reads and stores the trimmed text, and an empty
/// or oversized body is rejected instead of persisted.
fn review_feedback_text(feedback : String) -> Result[String, BoardError] {
  let trimmed = feedback.trim()
  if trimmed.is_empty() {
    return Err(InvalidInput(reason="review feedback must not be empty"))
  }
  if trimmed.length() > 4000 {
    return Err(
      InvalidInput(reason="review feedback must be at most 4000 characters"),
    )
  }
  Ok(trimmed.to_owned())
}

///|
/// Request changes for one Running Review attempt whose review is still
/// Pending. Unlike `RecordReview` this is a coupled decision: the attempt
/// records ChangesRequested and the ticket stores the durable feedback and
/// returns Review -> Ready in the same revision, so a fresh attempt can pick
/// the work item up without a second command. The attempt status stays
/// Running; the reviewer still finishes it separately (review independence).
fn propose_request_changes(
  state : BoardState,
  id : AttemptId,
  feedback : String,
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  if id.value == "" {
    return Err(InvalidInput(reason="attempt id must not be empty"))
  }
  if invalid_time(at_ms) {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  let feedback = match review_feedback_text(feedback) {
    Ok(text) => text
    Err(error) => return Err(error)
  }
  let attempt = match state.attempt(id) {
    Some(attempt) => attempt
    None => return Err(AttemptMissing(attempt=id))
  }
  if !(attempt.kind is Review) {
    return Err(
      InvalidInput(
        reason="requesting changes requires an attempt of kind Review",
      ),
    )
  }
  if !(attempt.status is Running) || !(attempt.review is Some(Pending)) {
    return Err(
      InvalidReviewTransition(
        attempt=id,
        current=attempt.review,
        requested=ChangesRequested,
      ),
    )
  }
  let task = match state.task(attempt.task_id) {
    Some(task) => task
    None => return Err(TaskMissing(task=attempt.task_id))
  }
  if !(task.stage is Review) {
    return Err(
      InvalidInput(reason="requesting changes requires a ticket under review"),
    )
  }
  let next = state.clone_detached()
  next.put_attempt({
    ..attempt,
    review: Some(ChangesRequested),
    updated_at_ms: at_ms,
  })
  next.put_task({
    ..task,
    stage: Ready,
    ready_since_ms: Some(at_ms),
    review_feedback: Some(feedback),
    updated_at_ms: at_ms,
  })
  next.bump_revision()
  Ok({
    next_state: next,
    events: [
      ReviewChangesRequested(task_id=task.id, attempt_id=id, feedback~, at_ms~),
    ],
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

///|
/// One detached whole-graph candidate, validated only after all nodes exist.
fn propose_expand_graph(
  state : BoardState,
  expansion : ExpansionId,
  candidates : Array[GraphTask],
  parent : BoardTaskId,
  workflow : String,
  at_ms : Int64,
) -> Result[BoardProposal, BoardError] {
  let candidates = candidates.map(candidate => candidate.copy_detached())
  match validate_expansion_input(expansion, candidates, workflow, at_ms) {
    Some(error) => return Err(error)
    None => ()
  }
  if state.task_ref(parent) is None {
    return Err(TaskMissing(task=parent))
  }
  if state.expansion(expansion) is Some(_) {
    return Err(DuplicateExpansion(expansion~))
  }
  let next = state.clone_detached()
  let tasks : Array[BoardTask] = []
  for candidate in candidates {
    if next.task_ref(candidate.id) is Some(_) {
      return Err(DuplicateTask(task=candidate.id))
    }
    let task : BoardTask = {
      id: candidate.id,
      title: candidate.title,
      description: candidate.description,
      stage: Created,
      priority: candidate.priority,
      definition_of_done: candidate.definition_of_done.copy(),
      dependencies: candidate.dependencies.copy(),
      created_at_ms: at_ms,
      updated_at_ms: at_ms,
      ready_since_ms: None,
      user_story: "",
      implementation_suggestions: "",
      model: None,
      review: None,
      review_feedback: None,
    }
    next.put_task(task)
    tasks.push(task.copy_detached())
  }
  // The ordinary command DAG validator sees every forward reference.
  for candidate in candidates {
    match validate_dependencies(next, candidate.id, candidate.dependencies) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  let digest = expansion_content_digest(
    expansion~,
    candidates~,
    parent~,
    workflow~,
  )
  let record = expansion_record(
    expansion~,
    candidates~,
    parent~,
    workflow~,
    digest~,
    at_ms~,
  )
  next.put_expansion(record)
  next.bump_revision()
  Ok({
    next_state: next,
    events: [
      GraphExpanded(
        expansion~,
        tasks~,
        parent~,
        workflow~,
        mapping=record.mapping.copy(),
        digest~,
        at_ms~,
      ),
    ],
  })
}
