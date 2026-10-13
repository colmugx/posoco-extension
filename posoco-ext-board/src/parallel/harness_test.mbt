///|
/// Shared deterministic harness for the ParallelWorkflowRunner blackbox tests.
/// Every timing decision is explicit: progress is awaited through bounded
/// cooperative yields, keyed holds and an injected clock; the only real timers
/// are the ones a test deliberately holds.

///|
/// Deterministic clock handed to the runner. Tests advance it explicitly;
/// a stopped clock never replenishes or consumes budget on its own.
struct ParallelClock {
  mut now_ms : Int64
}

///|
fn parallel_clock(now~ : Int64 = 0L) -> ParallelClock {
  { now_ms: now, }
}

///|
/// Trusted host resolver behind `BoardExecutionInputResolver`. Availability is
/// synchronous metadata over "task/attempt" pairs; every resolve allocates a
/// fresh execution/session identity and explicit ephemeral input. `stale_left`
/// optionally mutates the Board before authorization to force StalePlan
/// results deterministically.
struct ParallelResolver {
  available : Array[String]
  denied : Array[String]
  mut seq : Int32
  execution_ids : Array[String]
  session_ids : Array[String]
  inputs : Array[String]
  resolved_attempts : Array[String]
  mut stale_backend : @backend.BoardBackend?
  mut stale_left : Int32
}

///|
fn parallel_resolver(available~ : Array[String]) -> ParallelResolver {
  {
    available,
    denied: [],
    seq: 0,
    execution_ids: [],
    session_ids: [],
    inputs: [],
    resolved_attempts: [],
    stale_backend: None,
    stale_left: 0,
  }
}

///|
impl @orchestration.BoardExecutionInputResolver for ParallelResolver with fn availability(
  self,
  candidate,
) {
  let id = "\{candidate.task_id}/\{candidate.attempt_id}"
  if self.denied.contains(id) {
    @orchestration.Denied
  } else if self.available.contains(id) {
    @orchestration.Available
  } else {
    @orchestration.Missing
  }
}

///|
impl @orchestration.BoardExecutionInputResolver for ParallelResolver with fn resolve(
  self,
  candidate,
) {
  self.seq += 1
  let execution_id = "parallel-exec-\{self.seq}"
  let session_id = "parallel-session-\{self.seq}"
  let input = "explicit parallel input \{self.seq}"
  self.execution_ids.push(execution_id)
  self.session_ids.push(session_id)
  self.inputs.push(input)
  self.resolved_attempts.push(candidate.attempt_id)
  match self.stale_backend {
    Some(backend) if self.stale_left > 0 => {
      self.stale_left -= 1
      parallel_command(backend, "board.task.create", {
        "id": "stale-task-\{self.seq}",
        "title": "Stale probe \{self.seq}",
        "description": "",
        "priority": "normal",
        "definition_of_done": [],
        "dependencies": [],
      })
    }
    _ => ()
  }
  @orchestration.Authorized({
    execution_id,
    session_id,
    input,
    timeout_ms: None,
  })
}

///|
/// The exact authorization record behind one bound execution identity. The
/// runner's bounded StalePlan retry re-authorizes a still-eligible pinned
/// candidate BEFORE any reservation, so a resolver call can be discarded and
/// never admit anything. Journal and adapter IDs are therefore matched by
/// identity, never by resolver call order.
fn ParallelResolver::authorization_index(
  self : ParallelResolver,
  execution_id : String,
) -> Int32 {
  for index in 0..<self.execution_ids.length() {
    if self.execution_ids[index] == execution_id {
      return index
    }
  }
  abort("no authorization recorded for execution \{execution_id}")
}

///|
/// The last authorization recorded for one Attempt: a re-authorized dispatch
/// discards every earlier identity, so only this one can ever be journalled
/// or reach an Agent.
fn ParallelResolver::last_authorization_index(
  self : ParallelResolver,
  attempt_id : String,
) -> Int32 {
  let mut found = -1
  for index in 0..<self.resolved_attempts.length() {
    if self.resolved_attempts[index] == attempt_id {
      found = index
    }
  }
  if found < 0 {
    abort("no authorization recorded for attempt \{attempt_id}")
  }
  found
}

///|
/// One observed slot run: the occupied slot index and the exact Attempt.
struct ParallelWaveEntry {
  slot : Int32
  attempt_id : String
}

///|
/// Counters and gates shared by every per-slot driver. `holds` maps an Attempt
/// ID to the queue that keeps its run at a known point until the test releases
/// exactly that Attempt, so out-of-order completion is deterministic.
struct ParallelShared {
  mut runs : Int32
  mut active : Int32
  mut max_active : Int32
  mut slots : Int32
  run_order : Array[String]
  requests : Array[@execution.BoardExecutionRequest]
  entered : Array[ParallelWaveEntry]
  holds : Map[String, @aqueue.Queue[Unit]]
}

///|
fn parallel_shared() -> ParallelShared {
  {
    runs: 0,
    active: 0,
    max_active: 0,
    slots: 0,
    run_order: [],
    requests: [],
    entered: [],
    holds: Map([]),
  }
}

///|
/// Release exactly one held Attempt; other held members stay parked.
fn ParallelShared::release(self : ParallelShared, attempt_id : String) -> Unit {
  match self.holds.get(attempt_id) {
    Some(wait) => ignore(wait.try_put(()) catch { _ => false })
    None => ()
  }
}

///|
fn ParallelShared::entered_ids(self : ParallelShared) -> Array[String] {
  self.entered.map(entry => entry.attempt_id)
}

///|
fn ParallelShared::entered_slots(self : ParallelShared) -> Array[Int32] {
  self.entered.map(entry => entry.slot)
}

///|
/// Per-slot driver behind `BoardExecutionAdapter`. The factory gives every
/// slot its own instance, so no two slots ever share a driver. Per-Attempt
/// lists select the held, failed and gate-skipping (unresolved) members.
struct ParallelSlotAdapter {
  shared : ParallelShared
  slot : Int32
  hold_attempts : Array[String]
  failed_attempts : Array[String]
  nogate_attempts : Array[String]
}

///|
fn parallel_slot_adapter(
  shared : ParallelShared,
  slot~ : Int32,
  hold~ : Array[String] = [],
  fail~ : Array[String] = [],
  nogate~ : Array[String] = [],
) -> ParallelSlotAdapter {
  {
    shared,
    slot,
    hold_attempts: hold.copy(),
    failed_attempts: fail.copy(),
    nogate_attempts: nogate.copy(),
  }
}

///|
impl @execution.BoardExecutionAdapter for ParallelSlotAdapter with fn ready(
  _self,
) {
  true
}

///|
impl @execution.BoardExecutionAdapter for ParallelSlotAdapter with fn run(
  self,
  request,
  gate,
) {
  let shared = self.shared
  shared.runs += 1
  shared.requests.push(request)
  shared.run_order.push(request.attempt_id)
  shared.active += 1
  if shared.active > shared.max_active {
    shared.max_active = shared.active
  }
  if !self.nogate_attempts.contains(request.attempt_id) &&
    !gate({
      session_id: request.session_id,
      run_id: "parallel-run-\{shared.runs}",
      turn_id: "parallel-turn-\{shared.runs}",
    }) {
    shared.active -= 1
    return @execution.Failed
  }
  if self.hold_attempts.contains(request.attempt_id) {
    let wait = match shared.holds.get(request.attempt_id) {
      Some(wait) => wait
      None => {
        let wait = @aqueue.Queue(kind=Unbounded)
        shared.holds[request.attempt_id] = wait
        wait
      }
    }
    shared.entered.push({ slot: self.slot, attempt_id: request.attempt_id, })
    wait.get()
  } else {
    shared.entered.push({ slot: self.slot, attempt_id: request.attempt_id, })
  }
  shared.active -= 1
  if self.failed_attempts.contains(request.attempt_id) {
    return @execution.Failed
  }
  if self.nogate_attempts.contains(request.attempt_id) {
    return @execution.Interrupted
  }
  @execution.Completed
}

///|
/// One accepted Board command at the current revision.
async fn parallel_command(
  backend : @backend.BoardBackend,
  name : String,
  args : Json,
) -> Unit {
  let revision = backend.state().unwrap().revision
  let result = backend.handle_command({
    command_id: "parallel-test-\{name}-\{revision}",
    name,
    expected_revision: revision,
    args,
  })
  assert_true(result.accepted)
}

///|
/// One Ready task with `attempts` queued Execute Attempts named
/// "attempt-<task>-<n>". The harness uses an increasing server clock so
/// creation order, rather than incidental snapshot order, selects work.
async fn parallel_task(
  backend : @backend.BoardBackend,
  id : String,
  attempts~ : Int32 = 1,
) -> Unit {
  parallel_command(backend, "board.task.create", {
    "id": id,
    "title": "Parallel \{id}",
    "description": "",
    "priority": "normal",
    "definition_of_done": [],
    "dependencies": [],
  })
  for stage in ["refining", "ready"] {
    parallel_command(backend, "board.task.move", { "id": id, "to": stage })
  }
  for n in 1..<=attempts {
    parallel_command(backend, "board.attempt.queue", {
      "id": "attempt-\{id}-\{n}",
      "task_id": id,
      "kind": "execute",
    })
  }
}

///|
/// Online Board with one Ready task and one queued Execute Attempt per given
/// Task ID (or `attempts[i]` when given), driven through real commands only.
async fn parallel_board(
  group : @async.TaskGroup[Unit],
  tasks~ : Array[String],
  attempts~ : Array[Int32] = [],
) -> @backend.BoardBackend {
  let creation_clock = parallel_clock(now=1234L)
  let backend = @backend.BoardBackend(store=@store.MemoryBoardStore(), now_ms=() => {
    creation_clock.now_ms += 1L
    creation_clock.now_ms
  })
  backend.attach(group)
  assert_true(backend.bootstrap_snapshot() is Ok(_))
  for index, id in tasks {
    parallel_task(backend, id, attempts=attempts.get(index).unwrap_or(1))
  }
  backend
}

///|
struct ParallelHarness {
  backend : @backend.BoardBackend
  owner : @execution.BoardExecutionOwner
  orchestrator : @orchestration.BoardOrchestrator
  shared : ParallelShared
  resolver : ParallelResolver
  runner : @parallel.ParallelWorkflowRunner
  clock : ParallelClock
}

///|
/// One multi-slot owner (one isolated driver per slot), one orchestrator and
/// one runner over an online Board. The default resolver authorizes the first
/// Attempt of every task; the trusted-host execution policy is always enabled
/// here because the safe disabled default is covered by the S4C suite.
async fn parallel_harness(
  group : @async.TaskGroup[Unit],
  tasks~ : Array[String],
  capacity~ : Int32 = 1,
  clock~ : ParallelClock = parallel_clock(),
  resolver~ : ParallelResolver? = None,
  shared~ : ParallelShared? = None,
  store~ : &@execution.BoardExecutionStore = @execution.MemoryBoardExecutionStore(),
  hold~ : Array[String] = [],
  fail~ : Array[String] = [],
  nogate~ : Array[String] = [],
  attempts~ : Array[Int32] = [],
  policy_enabled~ : Bool = true,
) -> ParallelHarness {
  let backend = parallel_board(group, tasks~, attempts~)
  let available : Array[String] = []
  for id in tasks {
    available.push("\{id}/attempt-\{id}-1")
  }
  let resolver = match resolver {
    Some(resolver) => resolver
    None => parallel_resolver(available~)
  }
  let shared = match shared {
    Some(shared) => shared
    None => parallel_shared()
  }
  let hold_attempts = hold.copy()
  let failed_attempts = fail.copy()
  let nogate_attempts = nogate.copy()
  let owner = @execution.BoardExecutionOwner::with_slots(
    backend~,
    store~,
    adapter_factory=slot => {
      shared.slots += 1
      parallel_slot_adapter(
        shared,
        slot~,
        hold=hold_attempts,
        fail=failed_attempts,
        nogate=nogate_attempts,
      )
    },
    max_concurrency=capacity,
  ).unwrap()
  assert_true(owner.attach(group) is Ok(_))
  let orchestrator = @orchestration.BoardOrchestrator(
    owner~,
    resolver~,
    policy=@orchestration.ExecutionPolicy(enabled=policy_enabled),
  )
  let runner = @parallel.ParallelWorkflowRunner(orchestrator~, group~, now_ms=() => {
    clock.now_ms
  })
  { backend, owner, orchestrator, shared, resolver, runner, clock, }
}

///|
/// Explicit wave specification with valid defaults; tests override one field
/// at a time. Concurrency defaults to one like the production constructor.
fn parallel_spec(
  run_id~ : String = "run-1",
  scope~ : @workflow.WorkflowScope = @workflow.AllEligibleAtStart,
  max_executions~ : Int32 = 10,
  max_elapsed_ms~ : Int32 = 60000,
  execution_timeout_ms~ : Int32 = 30000,
  max_concurrency~ : Int32 = 1,
  failure_policy~ : @parallel.ParallelFailurePolicy = @parallel.StopOnFailure,
) -> @parallel.ParallelWorkflowSpec {
  {
    run_id,
    scope,
    max_executions,
    max_elapsed_ms,
    execution_timeout_ms,
    max_concurrency,
    failure_policy,
  }
}

///|
/// Yields until the predicate holds. Reaching the predicate requires only
/// scheduler progress, never wall-clock time, so the wait stays deterministic;
/// the bound only converts a lost wakeup into a test failure.
async fn parallel_yield_until(what~ : String, check~ : () -> Bool) -> Unit {
  for _ in 0..<100000 {
    if check() {
      return
    }
    @async.pause()
  }
  fail("timed out waiting for \{what}")
}

///|
async fn parallel_wait_phase(
  harness : ParallelHarness,
  phase : @workflow.WorkflowPhase,
) -> Unit {
  parallel_yield_until(what="phase", check=() => {
    harness.runner.status().phase == phase
  })
}

///|
/// Order-insensitive ID comparison for concurrently entered members.
fn parallel_same_ids(left : Array[String], right : Array[String]) -> Bool {
  left.length() == right.length() &&
  left.all(id => right.contains(id)) &&
  right.all(id => left.contains(id))
}

///|
/// Every journalled binding and every observed adapter request must be one
/// exact resolver authorization: the same record's execution ID, session ID,
/// Attempt and explicit input, and no execution identity is ever shared by
/// two runs. Extra pre-admission re-authorizations simply stay unbound.
fn parallel_assert_journal(harness : ParallelHarness) -> Unit raise {
  let bound : Array[Int32] = []
  for binding in harness.owner.bindings() {
    let record = harness.resolver.authorization_index(binding.execution_id)
    assert_eq(binding.session_id, harness.resolver.session_ids[record])
    assert_eq(binding.attempt_id, harness.resolver.resolved_attempts[record])
    assert_false(bound.contains(record))
    bound.push(record)
  }
  for request in harness.shared.requests {
    let record = harness.resolver.authorization_index(request.execution_id)
    assert_eq(request.session_id, harness.resolver.session_ids[record])
    assert_eq(request.input, harness.resolver.inputs[record])
  }
}

///|
/// Stringified telemetry payloads of the retained stream, for payload-leak
/// assertions.
fn parallel_event_payloads(backend : @backend.BoardBackend) -> Array[String] {
  let payloads : Array[String] = []
  for event in backend.event_history() {
    payloads.push(event.payload.stringify())
  }
  payloads
}
