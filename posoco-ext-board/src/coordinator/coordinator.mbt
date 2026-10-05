///|
/// Single-writer durable coordinator over the pure Board domain. One
/// Fuwaroid loop owns the committed `@domain.BoardState` and the persistence
/// pipeline: an accepted proposal becomes a pending candidate that only a
/// matching store persist may promote to committed state, so a revision
/// expectation wins at most once per durable version.
///
/// Synchronous Fuwaroid handlers never await. Every store access
/// (`load_recover_persist`, `persist`, reconciliation reload) runs on a
/// Fuwaroid `Supervisor[Unit]` worker that reports back with an actor
/// message; callers receive one bounded completion queue per submission.
/// Attach restores the durable board before submissions are proposed, and
/// `wait_ready` awaits that restore through a completion queue, never by
/// polling.

///|
/// Why durable state could not be established. `Store` carries the typed
/// store failure; `Domain` carries the typed rejection of a stored snapshot
/// by `BoardState::from_snapshot`.
pub(all) enum BoardRestoreError {
  Store(@store.BoardStoreError)
  Domain(@domain.BoardError)
} derive(Eq, Debug)

///|
pub extend BoardRestoreError with Eq::{equal, not_equal}

///|
pub extend BoardRestoreError with @debug.Debug::{to_repr}

///|
/// Why a coordinator request produced no domain answer.
pub(all) enum BoardCoordinatorError {
  /// attach(group) was never called.
  NotAttached
  /// The coordinator is shut down or draining, or the request could not be
  /// admitted.
  Closed
  /// No reply within the ask timeout. The request is not withdrawn; the
  /// loop may still serve it later.
  TimedOut
  /// The loop rejected the mutation with a typed domain error. The
  /// committed board is untouched.
  Rejected(@domain.BoardError)
  /// Restore or reconciliation is still in flight. Queries are answered
  /// explicitly instead of against unproven state; submissions are deferred.
  Initializing
  /// The submission was proposed but the store reported a failure before
  /// its visibility boundary. The committed board is unchanged.
  PersistFailed(@store.BoardStoreError)
  /// The store reported the write's durability as uncertain. The
  /// coordinator reloaded the authoritative board and resolved its own
  /// committed state; the caller must refresh before retrying.
  DurabilityUncertain(String)
  /// Durable state could not be established or re-established. The
  /// coordinator stays read-only (answering with this error) until restart.
  RestoreFailed(BoardRestoreError)
} derive(Eq, Debug)

///|
pub extend BoardCoordinatorError with Eq::{equal, not_equal}

///|
pub extend BoardCoordinatorError with @debug.Debug::{to_repr}

///|
/// Detached committed board together with the actual event-stream position
/// observed when the query was answered.
pub(all) struct BoardStreamSnapshot {
  board_snapshot : @domain.BoardStateSnapshot
  stream_seq : Int64
} derive(Eq, Debug)

///|
pub extend BoardStreamSnapshot with Eq::{equal, not_equal}

///|
pub extend BoardStreamSnapshot with @debug.Debug::{to_repr}

///|
/// Lifecycle phase of the durable coordinator, readable without blocking.
pub(all) enum BoardCoordinatorStatus {
  /// attach(group) was never called.
  Detached
  /// Startup restore is in flight.
  Loading
  /// The durable board is committed; submissions are admitted.
  Ready
  /// A persist reported uncertain durability; the authoritative snapshot is
  /// being reloaded.
  Reconciling
  /// Restore or reconciliation failed terminally; read-only until restart.
  Failed
  /// Shutdown started; draining the in-flight transaction.
  Stopping
  /// Shutdown finished.
  Stopped
} derive(Eq, Debug)

///|
pub extend BoardCoordinatorStatus with Eq::{equal, not_equal}

///|
pub extend BoardCoordinatorStatus with @debug.Debug::{to_repr}

///|
/// Synchronous handlers finish in microseconds; the ask timeout only guards
/// against a pathologically stalled loop.
let coordinator_ask_timeout_ms : Int = 5000

///|
pub struct BoardCoordinator {
  priv mut actor : @fuwaroid.Fuwaroid[BoardMsg, BoardQuery, BoardReply]?
  priv mut supervisor : @fuwaroid.Supervisor[Unit]?
  priv mut stopped : Bool
  priv mut draining : Bool
  priv mut generation : Int64
  priv mut waiter_seq : Int64
  priv shutdown_gate : @async.Mutex
  /// Status mirror. Written by the actor loop (the single writer of the
  /// phase), and by attach/shutdown outside the loop's lifetime.
  priv mut phase_status : BoardCoordinatorStatus
  priv store : &@store.BoardStore
  priv now_ms : () -> Int64
  /// Synchronous commit observer; runs on the loop after the committed
  /// state was assigned and before the committing caller is answered.
  priv on_commit : (@domain.BoardStateSnapshot, Array[@domain.BoardEvent]) -> Unit
  /// Live committed event-stream cursor. Called synchronously by the
  /// `StreamSnapshot` handler on the loop, so the answered boundary is the
  /// actual caller-owned sequence position (hub head) at query time.
  priv stream_cursor : () -> Int64
}

///|
/// Durable coordinator over `store`. `now_ms` supplies recovery and
/// reconciliation time and must be nonnegative. Defaults exist for tests:
/// a private `@store.MemoryBoardStore` and a deterministic zero clock.
pub fn BoardCoordinator::BoardCoordinator(
  store? : &@store.BoardStore = @store.MemoryBoardStore(),
  now_ms? : () -> Int64 = () => 0L,
  on_commit? : (@domain.BoardStateSnapshot, Array[@domain.BoardEvent]) -> Unit = (
    _,
    _,
  ) => (),
  stream_cursor? : () -> Int64 = () => 0L,
) -> BoardCoordinator {
  {
    actor: None,
    supervisor: None,
    stopped: false,
    draining: false,
    generation: 0L,
    waiter_seq: 0L,
    shutdown_gate: @async.Mutex(),
    phase_status: Detached,
    store,
    now_ms,
    on_commit,
    stream_cursor,
  }
}

///|
/// Spawn the single-writer loop, one `Supervisor[Unit]` for all store
/// workers, and the startup restore worker on the host's structured
/// concurrency scope — synchronously, without awaiting. Repeated attach is
/// idempotent within a shutdown cycle; after a shutdown a new attach
/// restores the board from the store again.
pub fn BoardCoordinator::attach(
  self : BoardCoordinator,
  group~ : @async.TaskGroup[Unit],
) -> Unit {
  if self.actor is Some(_) {
    return
  }
  let supervisor : @fuwaroid.Supervisor[Unit] = @fuwaroid.Supervisor(group~)
  let core : CoordinatorCore = {
    coordinator: self,
    store: self.store,
    now_ms: self.now_ms,
    supervisor,
  }
  let actor = @fuwaroid.Fuwaroid::spawn(
    group~,
    init=CoordinatorState::initial(),
    on_cmd=(ctx, state, msg) => coordinator_on_cmd(core, ctx, state, msg),
    on_query=(ctx, state, query) => {
      coordinator_on_query(core, ctx, state, query)
    },
  )
  self.actor = Some(actor)
  self.supervisor = Some(supervisor)
  self.stopped = false
  self.draining = false
  self.generation += 1L
  self.phase_status = Loading
  spawn_restore_worker(core, actor)
}

///|
/// Wait until startup restore settles: `Ok` once the durable board is
/// committed and submissions are admitted, `Err` when restore failed or the
/// coordinator is shutting down. Suspension happens on a completion queue;
/// there is no polling.
pub async fn BoardCoordinator::wait_ready(
  self : BoardCoordinator,
) -> Result[Unit, BoardCoordinatorError] {
  if self.draining {
    return Err(Closed)
  }
  let actor = match self.actor {
    Some(actor) => actor
    None => return Err(if self.stopped { Closed } else { NotAttached })
  }
  let completion : @aqueue.Queue[Result[Unit, BoardCoordinatorError]] = @aqueue.Queue(
    kind=@aqueue.Blocking(1),
  )
  self.waiter_seq += 1L
  let waiter = self.waiter_seq
  match actor.tell(WaitReady(waiter~, completion~)) {
    Ok(_) => ()
    Err(_) => return Err(Closed)
  }
  defer {
    completion.close()
    let _ = actor.tell(CancelReady(waiter~))
  }
  completion.get()
}

///|
/// Apply one domain mutation durably. The command is deep-copied before the
/// first suspension point. Returns the ordered typed events once the store
/// accepted the write, or a typed error: a domain rejection leaves the
/// committed state untouched, a pre-visibility store failure leaves it
/// untouched as well, and uncertain durability resolves through a reload
/// before this result is produced. Submissions that arrive while restore or
/// reconciliation is in flight are deferred in FIFO order and settle after
/// it.
pub async fn BoardCoordinator::submit(
  self : BoardCoordinator,
  command~ : @domain.BoardCommand,
) -> Result[Array[@domain.BoardEvent], BoardCoordinatorError] {
  let command = command.copy_detached()
  if self.draining {
    return Err(Closed)
  }
  let actor = match self.actor {
    Some(actor) => actor
    None => return Err(if self.stopped { Closed } else { NotAttached })
  }
  let completion : SubmissionCompletion = @aqueue.Queue(
    kind=@aqueue.Blocking(1),
  )
  match actor.tell(Submit(command, completion)) {
    Ok(_) => ()
    Err(_) => return Err(Closed)
  }
  // Cancellation withdraws the waiter, not its accepted transaction.
  defer completion.close()
  completion.get()
}

///|
async fn BoardCoordinator::request(
  self : BoardCoordinator,
  request : BoardQuery,
) -> Result[BoardReply, BoardCoordinatorError] {
  if self.draining {
    return Err(Closed)
  }
  let actor = match self.actor {
    Some(actor) => actor
    None => return Err(if self.stopped { Closed } else { NotAttached })
  }
  let reply = match actor.ask(request, timeout_ms=coordinator_ask_timeout_ms) {
    Ok(reply) => reply
    Err(failure) => return Err(coordinator_failure(failure))
  }
  match reply {
    ErrorReply(error) => Err(error)
    _ => Ok(reply)
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
/// Lifecycle phase, readable without blocking the loop.
pub fn BoardCoordinator::status(
  self : BoardCoordinator,
) -> BoardCoordinatorStatus {
  if self.draining && self.actor is Some(_) {
    Stopping
  } else {
    self.phase_status
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
/// Detached committed board together with the actual event-stream position
/// of the query: the configured `stream_cursor` callback is evaluated
/// synchronously on the loop while the committed state is copied, so the
/// answered boundary covers every event and telemetry item published up to
/// that instant. Answers like any other query: before the durable board
/// settled it reports the explicit phase error instead of a fabricated
/// stream position.
pub async fn BoardCoordinator::stream_snapshot(
  self : BoardCoordinator,
) -> Result[BoardStreamSnapshot, BoardCoordinatorError] {
  let reply = match self.request(StreamSnapshot) {
    Ok(reply) => reply
    Err(error) => return Err(error)
  }
  match reply {
    StreamSnapshotReply(stream) => Ok(stream)
    _ => abort("board coordinator: reply does not match a stream request")
  }
}

///|
/// Current committed event-stream position, read through the configured
/// callback without blocking the loop.
pub fn BoardCoordinator::stream_cursor(self : BoardCoordinator) -> Int64 {
  (self.stream_cursor)()
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
/// Final teardown: stop admission, let the current load, persist or
/// reconciliation transaction finish, reject deferred submissions
/// explicitly, close and join the loop, and only then shut the store-worker
/// supervisor down. Safe to call when never attached, already shut down, or
/// concurrently with other shutdowns and submissions; the entire cleanup is
/// shielded from cancellation, so a cancelled caller can never leave an
/// unjoined loop.
pub async fn BoardCoordinator::shutdown(self : BoardCoordinator) -> Unit {
  let generation = self.generation
  self.draining = true
  @async.protect_from_cancel(() => {
    self.shutdown_gate.acquire()
    defer self.shutdown_gate.release()
    // A concurrent shutdown must not tear down a subsequently reattached actor.
    if generation != self.generation {
      return
    }
    match self.actor {
      Some(actor) => {
        let supervisor = self.supervisor
        let _ = actor.tell(Stop)
        let _ = actor.join()
        match supervisor {
          Some(supervisor) => {
            let _ = supervisor.shutdown(timeout_ms=coordinator_ask_timeout_ms)
          }
          None => ()
        }
      }
      None => ()
    }
    self.actor = None
    self.supervisor = None
    self.stopped = true
    self.phase_status = Stopped
  })
}
