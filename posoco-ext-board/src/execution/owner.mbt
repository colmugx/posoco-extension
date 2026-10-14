///|
priv struct OwnedExecution {
  mut binding : BoardExecutionBinding
  mut started : Bool
  mut gate_called : Bool
  mut entered : Bool
  mut cancel_requested : Bool
}

///|
/// One isolated driver with at most one owned execution at a time. A slot is
/// freed only after its driver terminated and settlement was attempted.
priv struct ExecutionSlot {
  adapter : &BoardExecutionAdapter
  mut execution : OwnedExecution?
  mut worker : @async.Task[BoardExecutionBinding]?
}

///|
pub struct BoardExecutionHandle {
  priv execution_id_ : String
  priv task : @async.Task[BoardExecutionBinding]
}

///|
pub fn BoardExecutionHandle::execution_id(
  self : BoardExecutionHandle,
) -> String {
  self.execution_id_
}

///|
/// Returns only after the owned execution has terminated and settlement was
/// attempted. Unresolved is not success, and never implies permission to retry.
pub async fn BoardExecutionHandle::wait(
  self : BoardExecutionHandle,
) -> BoardExecutionBinding {
  self.task.wait()
}

///|
/// Opt-in trusted-host owner, separate from presentation and BoardBackend.
/// One owner and one journal per Board namespace; multi-process ownership is
/// not supported. Slots run isolated drivers concurrently, but every protected
/// journal section — reservation, scoped model gate + BoardStart + Running,
/// Finished + BoardFinish + Settled — serializes on one shared owner mutex.
/// The host must shut this down before shutting down the backend.
pub struct BoardExecutionOwner {
  priv backend : @backend.BoardBackend
  priv store : &BoardExecutionStore
  priv mutex : @async.Mutex
  priv mut group : @async.TaskGroup[Unit]?
  priv mut records_ : Array[BoardExecutionBinding]
  priv mut loaded : Bool
  priv mut closed : Bool
  priv mut busy : Bool
  priv mut poisoned : Bool
  priv slots : Array[ExecutionSlot]
}

///|
fn owner_with(
  backend~ : @backend.BoardBackend,
  store~ : &BoardExecutionStore,
  adapters~ : Array[&BoardExecutionAdapter],
) -> BoardExecutionOwner {
  let slots : Array[ExecutionSlot] = []
  for adapter in adapters {
    slots.push({ adapter, execution: None, worker: None, })
  }
  {
    backend,
    store,
    mutex: @async.Mutex::Mutex(),
    group: None,
    records_: [],
    loaded: false,
    closed: false,
    busy: false,
    poisoned: false,
    slots,
  }
}

///|
/// Single-slot owner over one explicit driver. Store is explicit: durable
/// hosts must provide durable journal storage. Memory storage is only
/// suitable for ephemeral/test Boards.
///
/// ```mbt check
/// test {
///   let owner = @execution.BoardExecutionOwner(
///     backend=@backend.BoardBackend(),
///     adapter=@execution.PosocoBoardExecutionAdapter(extensions=() => []),
///     store=@execution.MemoryBoardExecutionStore(),
///   )
///   assert_eq(owner.bindings().length(), 0)
///   assert_eq(owner.status().capacity, 1)
/// }
/// ```
pub fn BoardExecutionOwner::BoardExecutionOwner(
  backend~ : @backend.BoardBackend,
  adapter~ : &BoardExecutionAdapter,
  store~ : &BoardExecutionStore,
) -> BoardExecutionOwner {
  owner_with(backend~, store~, adapters=[adapter])
}

///|
/// Multi-slot owner over ONE store/journal. The factory is called exactly
/// once per slot index (0..<max_concurrency, bounded to 1..=8) and must
/// return an isolated driver that no other slot or host component shares.
/// Admission, global identity uniqueness, unresolved poisoning, exact-identity
/// cancellation and shutdown semantics match the single-slot owner.
///
/// ```mbt check
/// test {
///   let owner = @execution.BoardExecutionOwner::with_slots(
///     backend=@backend.BoardBackend(),
///     store=@execution.MemoryBoardExecutionStore(),
///     adapter_factory=_ => {
///       @execution.PosocoBoardExecutionAdapter(extensions=() => [])
///     },
///     max_concurrency=2,
///   ).unwrap()
///   assert_eq(owner.status().capacity, 2)
///   assert_eq(owner.status().available_slots, 2)
/// }
/// ```
pub fn BoardExecutionOwner::with_slots(
  backend~ : @backend.BoardBackend,
  store~ : &BoardExecutionStore,
  adapter_factory~ : (Int32) -> &BoardExecutionAdapter,
  max_concurrency~ : Int32 = 1,
) -> Result[BoardExecutionOwner, BoardExecutionError] {
  if max_concurrency < 1 || max_concurrency > 8 {
    return Err(InvalidRequest)
  }
  let adapters : Array[&BoardExecutionAdapter] = []
  for slot in 0..<max_concurrency {
    adapters.push(adapter_factory(slot))
  }
  Ok(owner_with(backend~, store~, adapters~))
}

///|
/// Loads identity history without replaying or settling recovered executions.
/// Any recovered non-settled record locks execution admission until an operator
/// reconciles it outside this v1 API. Board startup interruption is not proof of
/// external termination.
pub async fn BoardExecutionOwner::attach(
  self : BoardExecutionOwner,
  group : @async.TaskGroup[Unit],
) -> Result[Unit, BoardExecutionError] {
  if self.closed {
    return Err(Closed)
  }
  if self.loaded {
    return Ok(())
  }
  if self.busy {
    return Err(Busy)
  }
  self.busy = true
  defer {
    self.busy = false
  }
  @async.protect_from_cancel(() => {
    let loaded = self.store.load() catch { _ => Err(StoreUnavailable) }
    let records = match loaded {
      Ok(records) => records
      Err(error) => {
        self.poisoned = true
        return Err(error)
      }
    }
    if self.closed {
      return Err(Closed)
    }
    if !valid_bindings(records) {
      self.poisoned = true
      return Err(StoreUnavailable)
    }
    self.records_ = records.copy()
    self.poisoned = records.any(record => record.phase != Settled)
    self.group = Some(group)
    self.loaded = true
    Ok(())
  })
}

///|
/// Detached immutable metadata; no Agent input/output is retained here.
pub fn BoardExecutionOwner::bindings(
  self : BoardExecutionOwner,
) -> Array[BoardExecutionBinding] {
  self.records_.copy()
}

///|
fn valid_identity(value : String) -> Bool {
  !value.trim().is_empty() && value.length() <= 256
}

///|
fn eligible(
  snapshot : @domain.BoardStateSnapshot,
  request : BoardExecutionRequest,
) -> Bool {
  snapshot.tasks.any(task => task.id.value == request.task_id) &&
  snapshot.attempts.any(attempt => {
    attempt.id.value == request.attempt_id &&
    attempt.task_id.value == request.task_id &&
    attempt.kind is Execute &&
    attempt.status is Queued
  })
}

///|
fn BoardExecutionOwner::free_slot(self : BoardExecutionOwner) -> ExecutionSlot? {
  for slot in self.slots {
    if slot.execution is None && slot.adapter.ready() {
      return Some(slot)
    }
  }
  None
}

///|
/// Atomic in-process admission reserves before the first await. Durable identity
/// history rejects reuse even after completion; command IDs are not dedup keys.
/// Optional reservation_revision rejects stale selection before journalling.
/// A trusted, synchronous admission_guard receives detached state at reservation
/// and at the actual model gate. It must be side-effect-free; rejection before
/// the gate prevents provider effects but may leave a reserved identity unresolved.
/// Defaults preserve S4A's explicit queued-Execute admission policy.
/// Reservations serialize on the shared owner mutex: an active execution on the
/// same Task, any reused attempt/execution/session identity, and any unresolved
/// record are rejected globally across slots.
pub async fn BoardExecutionOwner::execute(
  self : BoardExecutionOwner,
  request : BoardExecutionRequest,
  admission_guard~ : (@domain.BoardStateSnapshot) -> Bool = _ => true,
  reservation_revision? : Int64,
) -> Result[BoardExecutionHandle, BoardExecutionError] {
  if self.closed {
    return Err(Closed)
  }
  if self.busy {
    return Err(Busy)
  }
  self.busy = true
  defer {
    self.busy = false
  }
  self.mutex.acquire()
  defer self.mutex.release()
  @async.protect_from_cancel(() => {
    if self.closed {
      return Err(Closed)
    }
    if self.slots.all(slot => slot.execution is Some(_)) {
      return Err(Busy)
    }
    if !self.loaded || self.poisoned {
      return Err(NotReady)
    }
    let slot = match self.free_slot() {
      Some(slot) => slot
      None => return Err(NotReady)
    }
    if !valid_identity(request.task_id) ||
      !valid_identity(request.attempt_id) ||
      !valid_identity(request.execution_id) ||
      !valid_identity(request.session_id) ||
      request.input.trim().is_empty() ||
      (request.timeout_ms is Some(timeout) && timeout <= 0) {
      return Err(InvalidRequest)
    }
    let same_active_task = self.slots.any(occupied => {
      match occupied.execution {
        Some(active) => active.binding.task_id == request.task_id
        None => false
      }
    })
    if same_active_task ||
      self.records_.any(record => {
        record.execution_id == request.execution_id ||
        record.attempt_id == request.attempt_id ||
        record.session_id == request.session_id
      }) {
      return Err(DuplicateIdentity)
    }
    let snapshot = match self.backend.state() {
      Ok(snapshot) => snapshot
      Err(_) => return Err(NotReady)
    }
    if (reservation_revision is Some(revision) && revision != snapshot.revision) ||
      !eligible(snapshot, request) ||
      !admission_guard(snapshot.copy_detached()) {
      return Err(IneligibleAttempt)
    }
    let owned : OwnedExecution = {
      binding: {
        task_id: request.task_id,
        attempt_id: request.attempt_id,
        execution_id: request.execution_id,
        session_id: request.session_id,
        run: None,
        phase: Reserved,
        outcome: None,
      },
      started: false,
      gate_called: false,
      entered: false,
      cancel_requested: false,
    }
    self.records_.push(owned.binding)
    if !self.persist_records() {
      return Err(StoreUnavailable)
    }
    if self.closed {
      self.poisoned = true
      return Err(Closed)
    }
    let group = match self.group {
      Some(group) => group
      None => return Err(NotReady)
    }
    slot.execution = Some(owned)
    let task = group.spawn(() => {
      self.drive(owned, request, admission_guard, slot)
    })
    slot.worker = Some(task)
    Ok({ execution_id_: request.execution_id, task, })
  })
}

///|
async fn BoardExecutionOwner::persist_records(
  self : BoardExecutionOwner,
) -> Bool {
  let persisted = self.store.persist(self.records_.copy()) catch {
    _ => Err(StoreUnavailable)
  }
  match persisted {
    Ok(_) => true
    Err(_) => {
      self.poisoned = true
      false
    }
  }
}

///|
async fn BoardExecutionOwner::record(
  self : BoardExecutionOwner,
  owned : OwnedExecution,
  binding : BoardExecutionBinding,
) -> Bool {
  owned.binding = binding
  for index in 0..<self.records_.length() {
    if self.records_[index].execution_id == binding.execution_id {
      self.records_[index] = binding
    }
  }
  let saved = !self.poisoned && self.persist_records()
  if !saved {
    // A visible write may have succeeded despite its error. Do not advertise
    // a durable terminal phase or attempt another write to resolve ambiguity.
    owned.binding = { ..binding, phase: Unresolved, }
    for index in 0..<self.records_.length() {
      if self.records_[index].execution_id == binding.execution_id {
        self.records_[index] = owned.binding
      }
    }
  }
  saved
}

///|
async fn BoardExecutionOwner::start(
  self : BoardExecutionOwner,
  owned : OwnedExecution,
  scope : BoardExecutionRun,
  admission_guard : (@domain.BoardStateSnapshot) -> Bool,
) -> Bool {
  if owned.gate_called ||
    self.closed ||
    self.poisoned ||
    scope.session_id != owned.binding.session_id ||
    !valid_identity(scope.run_id) ||
    !valid_identity(scope.turn_id) {
    return false
  }
  owned.gate_called = true
  @async.protect_from_cancel(() => {
    self.mutex.acquire()
    defer self.mutex.release()
    // Another slot may have poisoned or closed the owner while this driver
    // waited for the shared journal section.
    if self.closed || self.poisoned {
      return false
    }
    // Correlation reaches storage before Start or any model/tool execution.
    if !self.record(owned, { ..owned.binding, run: Some(scope), }) {
      return false
    }
    let snapshot = match self.backend.state() {
      Ok(value) => value
      Err(_) => return false
    }
    if !admission_guard(snapshot.copy_detached()) ||
      !snapshot.attempts.any(attempt => {
        attempt.id.value == owned.binding.attempt_id &&
        attempt.task_id.value == owned.binding.task_id &&
        attempt.kind is Execute &&
        attempt.status is Queued
      }) {
      return false
    }
    let result = self.backend.handle_command({
      command_id: "execution-start:" + owned.binding.execution_id,
      name: "board.attempt.start",
      expected_revision: snapshot.revision,
      args: { "id": owned.binding.attempt_id },
    })
    if !result.accepted {
      return false
    }
    owned.started = true
    if !self.record(owned, { ..owned.binding, phase: Running, }) {
      return false
    }
    ignore(
      self.backend.publish_telemetry(
        board_revision=snapshot.revision + 1L,
        kind="execution.started",
        scope=Some({
          session_id: Some(scope.session_id),
          run_id: Some(scope.run_id),
          turn_id: Some(scope.turn_id),
        }),
        payload={
          "execution_id": owned.binding.execution_id,
          "attempt_id": owned.binding.attempt_id,
        },
      ),
    )
    true
  })
}

///|
async fn BoardExecutionOwner::drive(
  self : BoardExecutionOwner,
  owned : OwnedExecution,
  request : BoardExecutionRequest,
  admission_guard : (@domain.BoardStateSnapshot) -> Bool,
  slot : ExecutionSlot,
) -> BoardExecutionBinding {
  // Cancellation bypasses catch in async 0.22; handle_cancellation confirms
  // the driver's structured lifetime has unwound before durable settlement.
  owned.entered = true
  let outcome = if owned.cancel_requested {
    Cancelled
  } else {
    match
      @async.handle_cancellation(() => {
        try {
          match request.timeout_ms {
            Some(timeout) =>
              @async.with_timeout(timeout, () => {
                slot.adapter.run(request, scope => {
                  self.start(owned, scope, admission_guard)
                })
              })
            None =>
              slot.adapter.run(request, scope => {
                self.start(owned, scope, admission_guard)
              })
          }
        } catch {
          @async.TimeoutError => TimedOut
          _ => Failed
        }
      }) {
      Some(outcome) => outcome
      None => Cancelled
    }
  }
  @async.protect_from_cancel(() => {
    self.finish(owned, outcome)
    slot.execution = None
    slot.worker = None
    owned.binding
  })
}

///|
fn outcome_wire(outcome : BoardExecutionOutcome) -> String {
  match outcome {
    Completed => "succeeded"
    Failed => "failed"
    Cancelled => "cancelled"
    TimedOut | Interrupted => "interrupted"
  }
}

///|
async fn BoardExecutionOwner::finish(
  self : BoardExecutionOwner,
  owned : OwnedExecution,
  outcome : BoardExecutionOutcome,
) -> Unit {
  self.mutex.acquire()
  defer self.mutex.release()
  if !owned.started || self.poisoned {
    ignore(
      self.record(owned, {
        ..owned.binding,
        phase: Unresolved,
        outcome: Some(outcome),
      }),
    )
    self.poisoned = true
    return
  }
  if !self.record(owned, {
      ..owned.binding,
      phase: Finished,
      outcome: Some(outcome),
    }) {
    return
  }
  let snapshot = match self.backend.state() {
    Ok(value) => value
    Err(_) => {
      self.poisoned = true
      return
    }
  }
  let running = snapshot.attempts.any(attempt => {
    attempt.id.value == owned.binding.attempt_id &&
    attempt.task_id.value == owned.binding.task_id &&
    attempt.kind is Execute &&
    attempt.status is Running
  })
  if !running {
    ignore(self.record(owned, { ..owned.binding, phase: Unresolved, }))
    self.poisoned = true
    return
  }
  let result = self.backend.handle_command({
    command_id: "execution-finish:" + owned.binding.execution_id,
    name: "board.attempt.finish",
    expected_revision: snapshot.revision,
    args: { "id": owned.binding.attempt_id, "outcome": outcome_wire(outcome) },
  })
  // One attempt only. Even a timeout/uncertain error can hide a commit.
  if result.accepted {
    ignore(self.record(owned, { ..owned.binding, phase: Settled, }))
  } else {
    ignore(self.record(owned, { ..owned.binding, phase: Unresolved, }))
    self.poisoned = true
  }
}

///|
/// Request cancellation only for this owner's exact active identity on its own
/// slot. Completion is confirmed by handle.wait, not by this acknowledgement.
/// Repeat is harmless.
pub fn BoardExecutionOwner::cancel(
  self : BoardExecutionOwner,
  execution_id : String,
) -> Result[Unit, BoardExecutionError] {
  for slot in self.slots {
    match (slot.execution, slot.worker) {
      (Some(owned), Some(task)) =>
        if owned.binding.execution_id == execution_id {
          owned.cancel_requested = true
          if owned.entered {
            task.cancel()
          }
          return Ok(())
        }
      _ => ()
    }
  }
  if self.records_.any(record => {
      record.execution_id == execution_id && record.outcome is Some(_)
    }) {
    Ok(())
  } else {
    Err(WrongExecution)
  }
}

///|
/// Stop admission then cancel/join every owned worker within the host's budget.
/// The timeout bounds the whole join, not each slot. False means cleanup is
/// unconfirmed; ownership is retained and admission stays closed. The enclosing
/// host TaskGroup still owns eventual cleanup.
pub async fn BoardExecutionOwner::shutdown(
  self : BoardExecutionOwner,
  timeout_ms~ : Int32 = 4000,
) -> Bool {
  self.closed = true
  @async.protect_from_cancel(() => {
    let workers : Array[@async.Task[BoardExecutionBinding]] = []
    for slot in self.slots {
      match slot.worker {
        Some(task) => {
          match slot.execution {
            Some(owned) => {
              owned.cancel_requested = true
              if owned.entered {
                task.cancel()
              }
            }
            None => ()
          }
          workers.push(task)
        }
        None => ()
      }
    }
    // Withdraw every occupied run even while a reservation is blocked on I/O.
    // Joining these workers cannot stand in for joining that admission caller.
    if self.busy || timeout_ms <= 0 {
      return false
    }
    if workers.is_empty() {
      return true
    }
    @async.with_timeout(timeout_ms, () => {
      for task in workers {
        ignore(task.wait())
      }
      true
    }) catch {
      _ => false
    }
  })
}
