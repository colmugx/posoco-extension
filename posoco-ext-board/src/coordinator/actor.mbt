///|
/// Actor-side vocabulary and the single-writer fold. Everything in this
/// file runs on the coordinator's Fuwaroid loop except the supervisor
/// workers spawned here, which only report back with `Worker` messages.

///|
/// Per-submission completion. A bounded async queue replaces the old
/// Ref-plus-query barrier: the loop puts exactly one result, the caller
/// gets it, and a cancelled caller leaves nothing behind in the actor.
type SubmissionCompletion = @aqueue.Queue[
  Result[Array[@domain.BoardEvent], BoardCoordinatorError],
]

///|
/// The one write in flight. `candidate` is the proposed successor state; it
/// becomes committed only when a persist report carrying the same ticket
/// succeeds (or a reconciliation proves it already landed).
priv struct PendingPersist {
  ticket : Int64
  candidate : @domain.BoardState
  events : Array[@domain.BoardEvent]
  completion : SubmissionCompletion
}

///|
/// Admitted submission waiting for the current transaction to settle. The
/// command is proposed freshly at settlement time, never before.
priv struct DeferredSubmission {
  command : @domain.BoardCommand
  completion : SubmissionCompletion
}

///|
/// Durable lifecycle phase behind `BoardCoordinatorStatus`. `Reconciling`
/// carries the uncertainty detail for the caller's reply; `RestoreFailed`
/// carries the typed cause every later request is answered with.
priv enum Phase {
  Loading
  Ready
  Reconciling(String)
  RestoreFailed(BoardRestoreError)
}

///|
/// Loop input. `Stop` is the shutdown message: it stops admission effects,
/// rejects deferred submissions explicitly and lets the loop quiesce once
/// the current transaction settled.
priv struct ReadyWaiter {
  waiter : Int64
  completion : @aqueue.Queue[Result[Unit, BoardCoordinatorError]]
}

///|
priv enum BoardMsg {
  Submit(@domain.BoardCommand, SubmissionCompletion)
  WaitReady(
    waiter~ : Int64,
    completion~ : @aqueue.Queue[Result[Unit, BoardCoordinatorError]]
  )
  CancelReady(waiter~ : Int64)
  Worker(WorkerReport)
  Stop
}

///|
/// What a supervisor worker reports. Every worker returns `Unit` and tells
/// its outcome; expected store errors travel inside the `Result`, never as
/// raised errors.
priv enum WorkerReport {
  Restored(Result[@store.BoardRecovery, @store.BoardStoreError])
  Persisted(ticket~ : Int64, outcome~ : Result[Unit, @store.BoardStoreError])
  Reloaded(
    ticket~ : Int64,
    outcome~ : Result[@domain.BoardStateSnapshot, @store.BoardStoreError]
  )
}

///|
priv enum BoardQuery {
  Snapshot
  StreamSnapshot
  GetTask(@domain.BoardTaskId)
  ListTasks
  GetAttempt(@domain.AttemptId)
  ListAttempts
  Revision
}

///|
priv enum BoardReply {
  SnapshotReply(@domain.BoardStateSnapshot)
  StreamSnapshotReply(BoardStreamSnapshot)
  TaskReply(@domain.BoardTask?)
  TasksReply(Array[@domain.BoardTask])
  AttemptReply(@domain.Attempt?)
  AttemptsReply(Array[@domain.Attempt])
  RevisionReply(Int64)
  ErrorReply(BoardCoordinatorError)
}

///|
/// Actor-owned state. `committed` is the last durably settled board;
/// `deferred` is FIFO; `stopping` is the shutdown latch set by `Stop`;
/// `restore_settled` latches the one startup report so late duplicates are
/// stale no-ops; `restored` records whether a durable board was ever
/// committed, so a failed reconciliation still serves reads read-only.
priv struct CoordinatorState {
  mut committed : @domain.BoardState
  mut pending : PendingPersist?
  deferred : @deque.Deque[DeferredSubmission]
  mut phase : Phase
  mut stopping : Bool
  mut restore_settled : Bool
  mut restored : Bool
  mut ticket_seq : Int64
  waiters : Array[ReadyWaiter]
}

///|
fn CoordinatorState::initial() -> CoordinatorState {
  {
    committed: @domain.BoardState::BoardState(),
    pending: None,
    deferred: @deque.Deque([]),
    phase: Loading,
    stopping: false,
    restore_settled: false,
    restored: false,
    ticket_seq: 0L,
    waiters: [],
  }
}

///|
fn CoordinatorState::status(self : CoordinatorState) -> BoardCoordinatorStatus {
  if self.stopping {
    return Stopping
  }
  match self.phase {
    Loading => Loading
    Ready => Ready
    Reconciling(_) => Reconciling
    RestoreFailed(_) => Failed
  }
}

///|
/// Shared loop dependencies captured by the handlers. Store workers are
/// owned by `supervisor`; the actor handle for their reports arrives through
/// the handler `Ctx`.
priv struct CoordinatorCore {
  coordinator : BoardCoordinator
  store : &@store.BoardStore
  now_ms : () -> Int64
  supervisor : @fuwaroid.Supervisor[Unit]
}

///|
/// A closed completion belongs to a cancelled caller, not a cancelled mutation.
fn[T] deliver(queue : @aqueue.Queue[T], value : T) -> Unit {
  let delivered = queue.try_put(value) catch {
    @aqueue.QueueAlreadyClosed => return
    error => abort("board completion failed: " + error.to_string())
  }
  if !delivered {
    abort("board coordinator: duplicate completion")
  }
}

///|
fn sync_status(core : CoordinatorCore, state : CoordinatorState) -> Unit {
  core.coordinator.phase_status = state.status()
}

///|
/// Shared commit bookkeeping for every durable settlement: replace the
/// committed board and observe the synchronous `on_commit` hook with deeply
/// detached inputs. The hook runs after the committed state was assigned
/// and before any caller — the committing submission or a parked ready
/// waiter — is answered. An empty event list is an unchanged load, not a
/// commit: it does not observe the hook.
fn coordinator_commit(
  core : CoordinatorCore,
  state : CoordinatorState,
  committed : @domain.BoardState,
  snapshot : @domain.BoardStateSnapshot,
  events : Array[@domain.BoardEvent],
) -> Unit {
  state.committed = committed
  if events.is_empty() {
    return
  }
  (core.coordinator.on_commit)(snapshot.copy_detached(), events.copy())
}

///|
fn coordinator_on_cmd(
  core : CoordinatorCore,
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
  msg : BoardMsg,
) -> CoordinatorState {
  match msg {
    Submit(command, completion) =>
      coordinator_admit(core, ctx, state, command, completion)
    WaitReady(waiter~, completion~) => {
      coordinator_add_waiter(state, waiter, completion)
      ()
    }
    CancelReady(waiter~) => coordinator_cancel_waiter(state, waiter)
    Worker(report) => coordinator_settle(core, ctx, state, report)
    Stop => coordinator_stop(ctx, state)
  }
  sync_status(core, state)
  state
}

///|
fn coordinator_admit(
  core : CoordinatorCore,
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
  command : @domain.BoardCommand,
  completion : SubmissionCompletion,
) -> Unit {
  if state.stopping {
    deliver(completion, Err(Closed))
    return
  }
  match state.phase {
    RestoreFailed(cause) => deliver(completion, Err(RestoreFailed(cause)))
    Loading | Reconciling(_) =>
      // The committed board is not settled yet; queue behind it in FIFO
      // order and propose freshly once it is.
      state.deferred.push_back({ command, completion, })
    Ready =>
      if state.pending is Some(_) {
        state.deferred.push_back({ command, completion, })
      } else {
        coordinator_propose_and_persist(core, ctx, state, {
          command,
          completion,
        })
      }
  }
}

///|
/// One propose, one persist transaction. A rejection completes the caller
/// immediately; an acceptance parks the candidate as pending until the
/// store report with the matching ticket arrives.
fn coordinator_propose_and_persist(
  core : CoordinatorCore,
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
  entry : DeferredSubmission,
) -> Unit {
  match @domain.BoardDomain::propose(state.committed, entry.command) {
    Err(error) => deliver(entry.completion, Err(Rejected(error)))
    Ok(proposal) => {
      state.ticket_seq = state.ticket_seq + 1L
      let ticket = state.ticket_seq
      state.pending = Some({
        ticket,
        candidate: proposal.next_state,
        events: proposal.events,
        completion: entry.completion,
      })
      let admitted = spawn_persist_worker(
        core,
        ctx.address,
        ticket,
        proposal.next_state.snapshot(),
        proposal.events,
      )
      if !admitted {
        state.pending = None
        deliver(
          entry.completion,
          Err(PersistFailed(@store.Io("board persist worker was not admitted"))),
        )
      }
    }
  }
}

///|
fn coordinator_add_waiter(
  state : CoordinatorState,
  waiter : Int64,
  completion : @aqueue.Queue[Result[Unit, BoardCoordinatorError]],
) -> Unit {
  if state.stopping {
    deliver(completion, Err(Closed))
    return
  }
  match state.phase {
    Ready => deliver(completion, Ok(()))
    RestoreFailed(cause) => deliver(completion, Err(RestoreFailed(cause)))
    Loading | Reconciling(_) => state.waiters.push({ waiter, completion, })
  }
}

///|
/// The caller went away (timeout or cancellation): withdraw its parked
/// waiter. Nobody else ever delivers into that queue again.
fn coordinator_cancel_waiter(state : CoordinatorState, waiter : Int64) -> Unit {
  for i in 0..<state.waiters.length() {
    if state.waiters[i].waiter == waiter {
      let _ = state.waiters.remove(i)
      return
    }
  }
}

///|
fn coordinator_settle(
  core : CoordinatorCore,
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
  report : WorkerReport,
) -> Unit {
  match report {
    Restored(outcome) => coordinator_restored(core, ctx, state, outcome)
    Persisted(ticket~, outcome~) =>
      coordinator_persisted(core, ctx, state, ticket, outcome)
    Reloaded(ticket~, outcome~) =>
      coordinator_reloaded(core, ctx, state, ticket, outcome)
  }
}

///|
/// Startup restore settled. The snapshot is validated through
/// `BoardState::from_snapshot` before it can become committed state; a
/// second `Restored` report is a stale no-op. A failed restore rejects the
/// submissions parked behind it explicitly with the typed cause.
fn coordinator_restored(
  core : CoordinatorCore,
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
  outcome : Result[@store.BoardRecovery, @store.BoardStoreError],
) -> Unit {
  if state.restore_settled {
    return
  }
  state.restore_settled = true
  match outcome {
    Ok(recovery) =>
      match @domain.BoardState::from_snapshot(recovery.snapshot) {
        Ok(restored) => {
          // The recovery persist is a durable transaction like any other:
          // its recovery mutations stream exactly once, an unchanged load
          // streams nothing.
          coordinator_commit(
            core,
            state,
            restored,
            recovery.snapshot,
            recovery.events,
          )
          state.restored = true
          state.phase = Ready
        }
        Err(error) => state.phase = RestoreFailed(Domain(error))
      }
    Err(error) => state.phase = RestoreFailed(Store(error))
  }
  match state.phase {
    Ready =>
      if state.stopping {
        // Shutdown won the race with the restore: nothing parked may
        // propose against the freshly restored board.
        coordinator_reject_deferred(state, Closed)
        coordinator_fail_waiters(state, Closed)
      } else {
        coordinator_ok_waiters(state)
      }
    RestoreFailed(cause) => {
      let rejection : BoardCoordinatorError = if state.stopping {
        Closed
      } else {
        RestoreFailed(cause)
      }
      coordinator_reject_deferred(state, rejection)
      coordinator_fail_waiters(state, rejection)
    }
    Loading | Reconciling(_) => ()
  }
  coordinator_after_settlement(core, ctx, state)
}

///|
/// Persist report. Only the report matching the one pending ticket settles
/// the transaction; stale or duplicate tickets are no-ops. While a
/// reconciliation owns the ticket, every further persist report for it is
/// a duplicate no-op.
fn coordinator_persisted(
  core : CoordinatorCore,
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
  ticket : Int64,
  outcome : Result[Unit, @store.BoardStoreError],
) -> Unit {
  if !(state.phase is Ready) {
    return
  }
  let pending = match state.pending {
    Some(pending) if pending.ticket == ticket => pending
    _ => return
  }
  match outcome {
    Ok(_) => {
      state.pending = None
      coordinator_commit(
        core,
        state,
        pending.candidate,
        pending.candidate.snapshot(),
        pending.events,
      )
      deliver(pending.completion, Ok(pending.events))
    }
    Err(@store.DurabilityUncertain(detail)) => {
      // The visibility boundary was crossed ambiguously: reload the
      // authoritative board before deciding. The caller's completion stays
      // open until the reconciliation resolves.
      state.phase = Reconciling(detail)
      if !spawn_reload_worker(core, ctx.address, ticket) {
        coordinator_reconcile_refused(core, ctx, state, ticket)
      }
      return
    }
    Err(error) => {
      // Pre-visibility failure: the committed board is untouched.
      state.pending = None
      deliver(pending.completion, Err(PersistFailed(error)))
    }
  }
  coordinator_after_settlement(core, ctx, state)
}

///|
/// Reconciliation report. Only the report carrying the reconciled ticket
/// while `Reconciling` resolves the transaction; stale or duplicate reports
/// are no-ops.
fn coordinator_reloaded(
  core : CoordinatorCore,
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
  ticket : Int64,
  outcome : Result[@domain.BoardStateSnapshot, @store.BoardStoreError],
) -> Unit {
  let detail = match state.phase {
    Reconciling(detail) => detail
    _ => return
  }
  let pending = match state.pending {
    Some(pending) if pending.ticket == ticket => pending
    _ => return
  }
  match outcome {
    Ok(snapshot) =>
      if snapshot_matches(snapshot, pending.candidate.snapshot()) {
        // The write had landed after all: adopt the candidate, but the
        // caller still learns the outcome was uncertain. The candidate
        // commits exactly once — the stream observes its events here.
        state.pending = None
        coordinator_commit(
          core,
          state,
          pending.candidate,
          pending.candidate.snapshot(),
          pending.events,
        )
        state.phase = Ready
        deliver(pending.completion, Err(DurabilityUncertain(detail)))
        coordinator_ok_waiters(state)
      } else if snapshot_matches(snapshot, state.committed.snapshot()) {
        // The write never became visible: keep the prior committed board.
        state.pending = None
        state.phase = Ready
        deliver(pending.completion, Err(DurabilityUncertain(detail)))
        coordinator_ok_waiters(state)
      } else {
        // The authoritative board matches neither version; no committed
        // state can be proven any more, so the coordinator turns read-only
        // and everything parked behind the transaction is rejected.
        let cause : BoardRestoreError = Store(
          @store.DurabilityUncertain(
            "reloaded board matches neither the attempted write nor the prior state",
          ),
        )
        state.pending = None
        state.phase = RestoreFailed(cause)
        deliver(pending.completion, Err(RestoreFailed(cause)))
        coordinator_reject_deferred(state, RestoreFailed(cause))
        coordinator_fail_waiters(state, RestoreFailed(cause))
      }
    Err(error) => {
      let cause : BoardRestoreError = Store(error)
      state.pending = None
      state.phase = RestoreFailed(cause)
      deliver(pending.completion, Err(RestoreFailed(cause)))
      coordinator_reject_deferred(state, RestoreFailed(cause))
      coordinator_fail_waiters(state, RestoreFailed(cause))
    }
  }
  coordinator_after_settlement(core, ctx, state)
}

///|
fn coordinator_reconcile_refused(
  core : CoordinatorCore,
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
  ticket : Int64,
) -> Unit {
  coordinator_reloaded(
    core,
    ctx,
    state,
    ticket,
    Err(@store.Io("board reconciliation worker was not admitted")),
  )
}

///|
/// After a transaction settled: drain deferred submissions while ready, or
/// quiesce the stopping loop once nothing is in flight.
fn coordinator_after_settlement(
  core : CoordinatorCore,
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
) -> Unit {
  if state.stopping {
    coordinator_maybe_quiesce(ctx, state)
    return
  }
  while state.phase is Ready && state.pending is None {
    match state.deferred.pop_front() {
      None => break
      Some(entry) => coordinator_propose_and_persist(core, ctx, state, entry)
    }
  }
}

///|
fn coordinator_stop(
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
) -> Unit {
  state.stopping = true
  // Reject deferred submissions explicitly; none of them was proposed.
  coordinator_reject_deferred(state, Closed)
  coordinator_fail_waiters(state, Closed)
  coordinator_maybe_quiesce(ctx, state)
}

///|
/// Reject every parked submission with one typed error. Deferred
/// submissions were never proposed, so rejecting them cannot leave state
/// behind.
fn coordinator_reject_deferred(
  state : CoordinatorState,
  error : BoardCoordinatorError,
) -> Unit {
  for entry in state.deferred {
    deliver(entry.completion, Err(error))
  }
  state.deferred.clear()
}

///|
/// The loop closes itself only once nothing is in flight: the startup
/// report arrived, no persist is pending and no submission is parked. Until
/// then a stopping loop keeps serving so the current load, persist or
/// reconciliation can still report.
fn coordinator_maybe_quiesce(
  ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
) -> Unit {
  if state.restore_settled && state.pending is None && state.deferred.is_empty() {
    ctx.address.close()
  }
}

///|
fn coordinator_ok_waiters(state : CoordinatorState) -> Unit {
  for waiter in state.waiters {
    deliver(waiter.completion, Ok(()))
  }
  state.waiters.clear()
}

///|
fn coordinator_fail_waiters(
  state : CoordinatorState,
  error : BoardCoordinatorError,
) -> Unit {
  for waiter in state.waiters {
    deliver(waiter.completion, Err(error))
  }
  state.waiters.clear()
}

///|
/// Read-only query fold. Until the durable board is settled the loop
/// answers explicitly instead of guessing state.
fn coordinator_on_query(
  core : CoordinatorCore,
  _ctx : @fuwaroid.Ctx[BoardMsg, BoardQuery, BoardReply],
  state : CoordinatorState,
  query : BoardQuery,
) -> (CoordinatorState, BoardReply) {
  if state.stopping {
    return (state, ErrorReply(Closed))
  }
  match state.phase {
    Loading | Reconciling(_) => return (state, ErrorReply(Initializing))
    RestoreFailed(cause) =>
      // Read-only after a durable failure. A coordinator that never
      // restored has no board to serve and answers with the typed cause;
      // one that already restored keeps serving the last settled board.
      if !state.restored {
        return (state, ErrorReply(RestoreFailed(cause)))
      }
    Ready => ()
  }
  let reply = match query {
    Snapshot => SnapshotReply(state.committed.snapshot())
    StreamSnapshot =>
      // The callback is evaluated while the loop owns the committed state,
      // so board and boundary answer one consistent instant.
      StreamSnapshotReply({
        board_snapshot: state.committed.snapshot(),
        stream_seq: (core.coordinator.stream_cursor)(),
      })
    GetTask(id) => TaskReply(state.committed.task(id))
    ListTasks => TasksReply(state.committed.tasks())
    GetAttempt(id) => AttemptReply(state.committed.attempt(id))
    ListAttempts => AttemptsReply(state.committed.attempts())
    Revision => RevisionReply(state.committed.revision())
  }
  (state, reply)
}

///|
/// Full-state canonical equality between the reloaded authoritative
/// snapshot and a local version. Task and attempt order is irrelevant (the
/// storage codec may reorder); every field and the revision must match.
fn snapshot_matches(
  left : @domain.BoardStateSnapshot,
  right : @domain.BoardStateSnapshot,
) -> Bool {
  if left.revision != right.revision {
    return false
  }
  if left.tasks.length() != right.tasks.length() {
    return false
  }
  let index : Map[String, @domain.BoardTask] = Map::from_array([])
  for task in left.tasks {
    index[task.id.value] = task
  }
  for task in right.tasks {
    let other = match index.get(task.id.value) {
      Some(other) => other
      None => return false
    }
    if other != task {
      return false
    }
  }
  if left.attempts.length() != right.attempts.length() {
    return false
  }
  let attempts : Map[String, @domain.Attempt] = Map::from_array([])
  for attempt in left.attempts {
    attempts[attempt.id.value] = attempt
  }
  for attempt in right.attempts {
    let other = match attempts.get(attempt.id.value) {
      Some(other) => other
      None => return false
    }
    if other != attempt {
      return false
    }
  }
  true
}
