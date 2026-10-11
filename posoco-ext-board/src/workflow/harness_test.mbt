///|
/// Shared deterministic harness for the SequentialWorkflowRunner blackbox
/// tests. Every timing decision is explicit: progress is awaited through
/// queues and cooperative yields, wall-clock budgets use an injected clock,
/// and the only real timers are the ones a test deliberately holds.

///|
/// Deterministic clock handed to the runner. Tests advance it explicitly;
/// a stopped clock never replenishes or consumes budget on its own.
struct FakeClock {
  mut now_ms : Int64
}

///|
fn fake_clock(now? : Int64 = 0L) -> FakeClock {
  { now_ms: now, }
}

///|
/// Trusted host resolver behind `BoardExecutionInputResolver`. Availability is
/// synchronous metadata over "task/attempt" pairs; every resolve allocates a
/// fresh execution/session identity and explicit ephemeral input. `stale_left`
/// optionally mutates the Board before authorization to force StalePlan
/// results deterministically.
struct ScriptedResolver {
  available : Array[String]
  denied : Array[String]
  mut seq : Int
  execution_ids : Array[String]
  session_ids : Array[String]
  inputs : Array[String]
  resolved_attempts : Array[String]
  mut stale_backend : @backend.BoardBackend?
  mut stale_left : Int
  mut delay_ms : Int
}

///|
fn scripted_resolver(available~ : Array[String]) -> ScriptedResolver {
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
    delay_ms: 0,
  }
}

///|
impl @orchestration.BoardExecutionInputResolver for ScriptedResolver with fn availability(
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
impl @orchestration.BoardExecutionInputResolver for ScriptedResolver with fn resolve(
  self,
  candidate,
) {
  if self.delay_ms > 0 {
    @async.sleep(self.delay_ms)
  }
  self.seq += 1
  let execution_id = "workflow-exec-\{self.seq}"
  let session_id = "workflow-session-\{self.seq}"
  let input = "explicit workflow input \{self.seq}"
  self.execution_ids.push(execution_id)
  self.session_ids.push(session_id)
  self.inputs.push(input)
  self.resolved_attempts.push(candidate.attempt_id)
  match self.stale_backend {
    Some(backend) if self.stale_left > 0 => {
      self.stale_left -= 1
      workflow_command(backend, "board.task.create", {
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
/// Deterministic execution driver behind `BoardExecutionAdapter`. It records
/// the exact request and the run order, never overlaps runs, and exposes
/// entered/release queues so tests hold an admitted execution at a known
/// point. `call_gate=false` skips the durable Start gate entirely, which the
/// owner settles as an unconfirmed (Unresolved) journal record.
struct ScriptedAdapter {
  ready_ : Bool
  mut failures_left : Int
  outcome : @execution.BoardExecutionOutcome
  hold : Bool
  call_gate : Bool
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  requests : Array[@execution.BoardExecutionRequest]
  run_order : Array[String]
  mut runs : Int
  mut active : Int
  mut max_active : Int
}

///|
fn scripted_adapter(
  hold? : Bool = false,
  failures? : Int = 0,
  call_gate? : Bool = true,
  outcome? : @execution.BoardExecutionOutcome = @execution.Completed,
) -> ScriptedAdapter {
  {
    ready_: true,
    failures_left: failures,
    outcome,
    hold,
    call_gate,
    entered: @aqueue.Queue(kind=Unbounded),
    release: @aqueue.Queue(kind=Unbounded),
    requests: [],
    run_order: [],
    runs: 0,
    active: 0,
    max_active: 0,
  }
}

///|
impl @execution.BoardExecutionAdapter for ScriptedAdapter with fn ready(self) {
  self.ready_
}

///|
impl @execution.BoardExecutionAdapter for ScriptedAdapter with fn run(
  self,
  request,
  gate,
) {
  self.runs += 1
  self.requests.push(request)
  self.run_order.push(request.attempt_id)
  self.active += 1
  if self.active > self.max_active {
    self.max_active = self.active
  }
  if self.call_gate {
    if !gate({
        session_id: request.session_id,
        run_id: "workflow-run-\{self.runs}",
        turn_id: "workflow-turn-\{self.runs}",
      }) {
      self.active -= 1
      return @execution.Failed
    }
  }
  self.entered.put(())
  if self.hold {
    self.release.get()
  }
  self.active -= 1
  if self.failures_left > 0 {
    self.failures_left -= 1
    return @execution.Failed
  }
  self.outcome
}

///|
/// One accepted Board command at the current revision.
async fn workflow_command(
  backend : @backend.BoardBackend,
  name : String,
  args : Json,
) -> Unit {
  let revision = backend.state().unwrap().revision
  let result = backend.handle_command({
    command_id: "workflow-test-\{name}-\{revision}",
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
async fn workflow_task(
  backend : @backend.BoardBackend,
  id : String,
  attempts? : Int = 1,
) -> Unit {
  workflow_command(backend, "board.task.create", {
    "id": id,
    "title": "Workflow \{id}",
    "description": "",
    "priority": "normal",
    "definition_of_done": [],
    "dependencies": [],
  })
  for stage in ["refining", "ready"] {
    workflow_command(backend, "board.task.move", { "id": id, "to": stage })
  }
  for n in 1..<=attempts {
    workflow_command(backend, "board.attempt.queue", {
      "id": "attempt-\{id}-\{n}",
      "task_id": id,
      "kind": "execute",
    })
  }
}

///|
/// Online Board with one Ready task and one queued Execute Attempt per given
/// Task ID, driven through real commands only.
async fn workflow_board(
  group : @async.TaskGroup[Unit],
  tasks~ : Array[String],
) -> @backend.BoardBackend {
  let creation_clock = fake_clock(now=1234L)
  let backend = @backend.BoardBackend(store=@store.MemoryBoardStore(), now_ms=() => {
    creation_clock.now_ms += 1L
    creation_clock.now_ms
  })
  backend.attach(group)
  assert_true(backend.bootstrap_snapshot() is Ok(_))
  for id in tasks {
    workflow_task(backend, id)
  }
  backend
}

///|
struct WorkflowHarness {
  backend : @backend.BoardBackend
  owner : @execution.BoardExecutionOwner
  orchestrator : @orchestration.BoardOrchestrator
  adapter : ScriptedAdapter
  resolver : ScriptedResolver
  runner : @workflow.SequentialWorkflowRunner
  clock : FakeClock
}

///|
/// One owner, one orchestrator and one runner over an online Board. The
/// default resolver authorizes the first Attempt of every task; tests extend
/// availability for later Attempts explicitly. The execution policy defaults
/// to the trusted-host opt-in; `policy_enabled=false` exercises the safe
/// disabled default.
async fn workflow_harness(
  group : @async.TaskGroup[Unit],
  tasks~ : Array[String],
  adapter? : ScriptedAdapter = scripted_adapter(),
  clock? : FakeClock = fake_clock(),
  resolver? : ScriptedResolver? = None,
  store? : &@execution.BoardExecutionStore = @execution.MemoryBoardExecutionStore(),
  policy_enabled? : Bool = true,
) -> WorkflowHarness {
  let backend = workflow_board(group, tasks~)
  let available : Array[String] = []
  for id in tasks {
    available.push("\{id}/attempt-\{id}-1")
  }
  let resolver = match resolver {
    Some(resolver) => resolver
    None => scripted_resolver(available~)
  }
  let owner = @execution.BoardExecutionOwner(backend~, adapter~, store~)
  assert_true(owner.attach(group) is Ok(_))
  let orchestrator = @orchestration.BoardOrchestrator(
    owner~,
    resolver~,
    policy=@orchestration.ExecutionPolicy(enabled=policy_enabled),
  )
  let runner = @workflow.SequentialWorkflowRunner(orchestrator~, group~, now_ms=() => {
    clock.now_ms
  })
  { backend, owner, orchestrator, adapter, resolver, runner, clock, }
}

///|
/// Explicit run specification with valid defaults; tests override one field
/// at a time.
fn workflow_spec(
  run_id? : String = "run-1",
  scope? : @workflow.WorkflowScope = @workflow.AllEligibleAtStart,
  max_executions? : Int = 10,
  max_elapsed_ms? : Int = 60000,
  execution_timeout_ms? : Int = 30000,
  failure_policy? : @workflow.WorkflowFailurePolicy = @workflow.StopOnFailure,
) -> @workflow.WorkflowRunSpec {
  {
    run_id,
    scope,
    max_executions,
    max_elapsed_ms,
    execution_timeout_ms,
    failure_policy,
  }
}

///|
/// Yields until the predicate holds. Reaching the predicate requires only
/// scheduler progress, never wall-clock time, so the wait stays deterministic;
/// the bound only converts a lost wakeup into a test failure.
async fn workflow_yield_until(what~ : String, check~ : () -> Bool) -> Unit {
  for _ in 0..<100000 {
    if check() {
      return
    }
    @async.pause()
  }
  fail("timed out waiting for \{what}")
}

///|
async fn workflow_wait_phase(
  harness : WorkflowHarness,
  phase : @workflow.WorkflowPhase,
) -> Unit {
  workflow_yield_until(what="phase", check=() => {
    workflow_phase_eq(harness.runner.status().phase, phase)
  })
}

///|
fn workflow_phase_eq(
  left : @workflow.WorkflowPhase,
  right : @workflow.WorkflowPhase,
) -> Bool {
  match (left, right) {
    (@workflow.Idle, @workflow.Idle) => true
    (@workflow.Running, @workflow.Running) => true
    (@workflow.Pausing, @workflow.Pausing) => true
    (@workflow.Paused, @workflow.Paused) => true
    (@workflow.Stopping, @workflow.Stopping) => true
    (@workflow.Stopped, @workflow.Stopped) => true
    (@workflow.Completed, @workflow.Completed) => true
    (@workflow.Failed, @workflow.Failed) => true
    (@workflow.Unresolved, @workflow.Unresolved) => true
    _ => false
  }
}

///|
/// Stringified telemetry payloads of the retained stream, for payload-leak
/// assertions.
fn workflow_event_payloads(backend : @backend.BoardBackend) -> Array[String] {
  let payloads : Array[String] = []
  for event in backend.event_history() {
    payloads.push(event.payload.stringify())
  }
  payloads
}
