///|
/// Single-writer coordinator over the pure Board domain. One Fuwaroid loop
/// owns the committed `@domain.BoardState`: every mutation and query is a
/// FIFO mailbox message, so concurrent callers serialize and exactly one
/// revision expectation can win per state version.
///
/// S3A commits in memory only. The S3B persistence barrier belongs in
/// `coordinator_fold_command`, between an accepted proposal and
/// the replacement of the committed state.

///|
/// Completion belongs to this submission, never to the authoritative state.
priv struct BoardMutation {
  command : @domain.BoardCommand
  completion : Ref[Result[Array[@domain.BoardEvent], @domain.BoardError]?]
}

///|
priv enum BoardQuery {
  Snapshot
  GetTask(@domain.BoardTaskId)
  ListTasks
  GetAttempt(@domain.AttemptId)
  ListAttempts
  Revision
}

///|
priv enum BoardReply {
  SnapshotReply(@domain.BoardStateSnapshot)
  TaskReply(@domain.BoardTask?)
  TasksReply(Array[@domain.BoardTask])
  AttemptReply(@domain.Attempt?)
  AttemptsReply(Array[@domain.Attempt])
  RevisionReply(Int64)
}

///|
/// Why a coordinator request produced no domain answer.
pub(all) enum BoardCoordinatorError {
  /// attach(group) was never called.
  NotAttached
  /// The coordinator is shut down, or the request could not be admitted.
  Closed
  /// No reply within the ask timeout. The request is not withdrawn; the
  /// loop may still serve it later.
  TimedOut
  /// The loop rejected the mutation with a typed domain error.
  Rejected(@domain.BoardError)
} derive(Eq, Debug)

///|
pub extend BoardCoordinatorError with Eq::{equal, not_equal}

///|
pub extend BoardCoordinatorError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Synchronous handlers finish in microseconds; the ask timeout only guards
/// against a pathologically stalled loop.
let coordinator_ask_timeout_ms : Int = 5000

///|
pub struct BoardCoordinator {
  priv mut actor : @fuwaroid.Fuwaroid[BoardMutation, BoardQuery, BoardReply]?
  priv mut stopped : Bool
}

///|
pub fn BoardCoordinator::BoardCoordinator() -> BoardCoordinator {
  { actor: None, stopped: false, }
}

///|
/// Spawn the single-writer loop on the host's structured-concurrency scope.
/// Repeated attach is idempotent: the loop, and therefore the committed
/// state, is created exactly once per shutdown cycle. After a shutdown a
/// new attach starts a fresh in-memory board (revision 0); durable restore
/// is the S3B persistence barrier's job.
pub fn BoardCoordinator::attach(
  self : BoardCoordinator,
  group~ : @async.TaskGroup[Unit],
) -> Unit {
  if self.actor is None {
    self.actor = Some(
      @fuwaroid.Fuwaroid::spawn(
        group~,
        init=@domain.BoardState::BoardState(),
        on_cmd=coordinator_fold_command,
        on_query=coordinator_fold_query,
      ),
    )
    self.stopped = false
  }
}

///|
fn coordinator_fold_command(
  _ctx : @fuwaroid.Ctx[BoardMutation, BoardQuery, BoardReply],
  state : @domain.BoardState,
  mutation : BoardMutation,
) -> @domain.BoardState {
  match @domain.BoardDomain::propose(state, mutation.command) {
    Ok(proposal) => {
      // S3A-only in-memory commit. S3B inserts persistence before this
      // replacement and completion; browser mutations remain unsupported.
      mutation.completion.val = Some(Ok(proposal.events))
      proposal.next_state
    }
    Err(error) => {
      mutation.completion.val = Some(Err(error))
      state
    }
  }
}

///|
fn coordinator_fold_query(
  _ctx : @fuwaroid.Ctx[BoardMutation, BoardQuery, BoardReply],
  state : @domain.BoardState,
  request : BoardQuery,
) -> (@domain.BoardState, BoardReply) {
  match request {
    Snapshot => (state, SnapshotReply(state.snapshot()))
    GetTask(id) => (state, TaskReply(state.task(id)))
    ListTasks => (state, TasksReply(state.tasks()))
    GetAttempt(id) => (state, AttemptReply(state.attempt(id)))
    ListAttempts => (state, AttemptsReply(state.attempts()))
    Revision => (state, RevisionReply(state.revision()))
  }
}

///|
fn coordinator_failure(failure : @fuwaroid.AskFailure) -> BoardCoordinatorError {
  match failure {
    TimedOut => TimedOut
    NotDelivered(_) | Stopped => Closed
  }
}

///|
async fn BoardCoordinator::request(
  self : BoardCoordinator,
  request : BoardQuery,
) -> Result[BoardReply, BoardCoordinatorError] {
  let actor = match self.actor {
    Some(actor) => actor
    None => return Err(if self.stopped { Closed } else { NotAttached })
  }
  match actor.ask(request, timeout_ms=coordinator_ask_timeout_ms) {
    Ok(reply) => Ok(reply)
    Err(failure) => Err(coordinator_failure(failure))
  }
}

///|
/// Apply one domain mutation. Returns the ordered typed events, or the
/// typed domain rejection; a rejection leaves the committed state and its
/// revision untouched.
pub async fn BoardCoordinator::submit(
  self : BoardCoordinator,
  command~ : @domain.BoardCommand,
) -> Result[Array[@domain.BoardEvent], BoardCoordinatorError] {
  // Deep-copy the command before the first suspension point: once the
  // envelope sits in the mailbox the loop reads it asynchronously, so a
  // caller mutating its arrays in the meantime must not alter what gets
  // validated and admitted.
  let command = command.copy_detached()
  let actor = match self.actor {
    Some(actor) => actor
    None => return Err(if self.stopped { Closed } else { NotAttached })
  }
  let completion = Ref(None)
  match actor.tell({ command, completion, }) {
    Ok(_) => ()
    Err(_) => return Err(Closed)
  }
  // A read-only query is a FIFO served barrier, not a mutation request.
  // Its reply proves on_cmd has filled this submission's completion.
  // Use the captured actor even if shutdown drops the coordinator handle.
  match actor.ask(Revision, timeout_ms=coordinator_ask_timeout_ms) {
    Ok(_) => ()
    Err(failure) => return Err(coordinator_failure(failure))
  }
  match completion.val {
    Some(Ok(events)) => Ok(events)
    Some(Err(error)) => Err(Rejected(error))
    None => abort("board coordinator: command not served before FIFO barrier")
  }
}

///|
/// Detached whole-board snapshot.
pub async fn BoardCoordinator::snapshot(
  self : BoardCoordinator,
) -> Result[@domain.BoardStateSnapshot, BoardCoordinatorError] {
  let reply = match self.request(Snapshot) {
    Ok(reply) => reply
    Err(error) => return Err(error)
  }
  match reply {
    SnapshotReply(snapshot) => Ok(snapshot)
    _ => abort("board coordinator: reply does not match a snapshot request")
  }
}

///|
pub async fn BoardCoordinator::task(
  self : BoardCoordinator,
  id~ : @domain.BoardTaskId,
) -> Result[@domain.BoardTask?, BoardCoordinatorError] {
  let reply = match self.request(GetTask(id)) {
    Ok(reply) => reply
    Err(error) => return Err(error)
  }
  match reply {
    TaskReply(task) => Ok(task)
    _ => abort("board coordinator: reply does not match a task request")
  }
}

///|
pub async fn BoardCoordinator::tasks(
  self : BoardCoordinator,
) -> Result[Array[@domain.BoardTask], BoardCoordinatorError] {
  let reply = match self.request(ListTasks) {
    Ok(reply) => reply
    Err(error) => return Err(error)
  }
  match reply {
    TasksReply(tasks) => Ok(tasks)
    _ => abort("board coordinator: reply does not match a tasks request")
  }
}

///|
pub async fn BoardCoordinator::attempt(
  self : BoardCoordinator,
  id~ : @domain.AttemptId,
) -> Result[@domain.Attempt?, BoardCoordinatorError] {
  let reply = match self.request(GetAttempt(id)) {
    Ok(reply) => reply
    Err(error) => return Err(error)
  }
  match reply {
    AttemptReply(attempt) => Ok(attempt)
    _ => abort("board coordinator: reply does not match an attempt request")
  }
}

///|
pub async fn BoardCoordinator::attempts(
  self : BoardCoordinator,
) -> Result[Array[@domain.Attempt], BoardCoordinatorError] {
  let reply = match self.request(ListAttempts) {
    Ok(reply) => reply
    Err(error) => return Err(error)
  }
  match reply {
    AttemptsReply(attempts) => Ok(attempts)
    _ => abort("board coordinator: reply does not match an attempts request")
  }
}

///|
pub async fn BoardCoordinator::revision(
  self : BoardCoordinator,
) -> Result[Int64, BoardCoordinatorError] {
  let reply = match self.request(Revision) {
    Ok(reply) => reply
    Err(error) => return Err(error)
  }
  match reply {
    RevisionReply(revision) => Ok(revision)
    _ => abort("board coordinator: reply does not match a revision request")
  }
}

///|
/// Final teardown: close admission, let the FIFO drain finish, join the
/// loop task, and drop the handle so a later attach starts fresh. Safe to
/// call when never attached or already shut down. The entire cleanup is
/// shielded from cancellation: a host scope cancelling during shutdown
/// still gets admission closed and the loop joined, never an orphan loop.
pub async fn BoardCoordinator::shutdown(self : BoardCoordinator) -> Unit {
  let actor = match self.actor {
    Some(actor) => actor
    None => return
  }
  @async.protect_from_cancel(() => {
    actor.close()
    let _ = actor.join()
    self.actor = None
    self.stopped = true
  })
}
