///|
struct OrchResolver {
  mut calls : Int32
  mut hint : @orchestration.ExecutionInputStatus
  mut resolution : @orchestration.ExecutionInputResolution?
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  block : Bool
  mut timeout_ms : Int32?
}

///|
fn orch_resolver(block~ : Bool = false) -> OrchResolver {
  {
    calls: 0,
    hint: @orchestration.Available,
    resolution: None,
    entered: @aqueue.Queue(kind=Unbounded),
    release: @aqueue.Queue(kind=Unbounded),
    block,
    timeout_ms: None,
  }
}

///|
impl @orchestration.BoardExecutionInputResolver for OrchResolver with fn availability(
  self,
  _candidate,
) {
  self.hint
}

///|
impl @orchestration.BoardExecutionInputResolver for OrchResolver with fn resolve(
  self,
  _candidate,
) {
  self.calls += 1
  self.entered.put(())
  if self.block {
    self.release.get()
  }
  match self.resolution {
    Some(resolution) => resolution
    None =>
      @orchestration.Authorized({
        execution_id: "exec-\{self.calls}",
        session_id: "session-\{self.calls}",
        input: "Explicit trusted host instruction",
        timeout_ms: self.timeout_ms,
      })
  }
}

///|
struct OrchAdapter {
  mut calls : Int32
  mut effects : Int32
  mut available : Bool
  mut seen_timeout : Int32?
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  before_gate : @aqueue.Queue[Unit]
  gate_release : @aqueue.Queue[Unit]
  block : Bool
  delay_gate : Bool
}

///|
fn orch_adapter(
  block~ : Bool = false,
  delay_gate~ : Bool = false,
) -> OrchAdapter {
  {
    calls: 0,
    effects: 0,
    available: true,
    seen_timeout: None,
    entered: @aqueue.Queue(kind=Unbounded),
    release: @aqueue.Queue(kind=Unbounded),
    before_gate: @aqueue.Queue(kind=Unbounded),
    gate_release: @aqueue.Queue(kind=Unbounded),
    block,
    delay_gate,
  }
}

///|
impl @execution.BoardExecutionAdapter for OrchAdapter with fn ready(self) {
  self.available
}

///|
impl @execution.BoardExecutionAdapter for OrchAdapter with fn run(
  self,
  request,
  start,
) {
  self.calls += 1
  self.seen_timeout = request.timeout_ms
  self.before_gate.put(())
  if self.delay_gate {
    self.gate_release.get()
  }
  if !start({
      session_id: request.session_id,
      run_id: "run-" + request.execution_id,
      turn_id: "turn",
    }) {
    return @execution.Failed
  }
  self.effects += 1
  self.entered.put(())
  if self.block {
    self.release.get()
  }
  @execution.Completed
}

///|
async fn orch_command(
  backend : @backend.BoardBackend,
  name : String,
  args : Json,
) -> Unit {
  let revision = backend.state().unwrap().revision
  let result = backend.handle_command({
    command_id: "test-\{revision}",
    name,
    expected_revision: revision,
    args,
  })
  assert_true(result.accepted)
}

///|
async fn orch_board(
  group : @async.TaskGroup[Unit],
  store~ : &@store.BoardStore = @store.MemoryBoardStore(),
) -> @backend.BoardBackend {
  let backend = @backend.BoardBackend(store~, now_ms=() => 1234L)
  backend.attach(group)
  assert_true(backend.bootstrap_snapshot() is Ok(_))
  orch_command(backend, "board.task.create", {
    "id": "task",
    "title": "Task",
    "description": "",
    "priority": "normal",
    "definition_of_done": [],
    "dependencies": [],
  })
  for stage in ["refining", "ready"] {
    orch_command(backend, "board.task.move", { "id": "task", "to": stage })
  }
  orch_command(backend, "board.attempt.queue", {
    "id": "attempt",
    "task_id": "task",
    "kind": "execute",
  })
  backend
}

///|
fn orch_facade(
  owner : @execution.BoardExecutionOwner,
  resolver : OrchResolver,
) -> @orchestration.BoardOrchestrator {
  @orchestration.BoardOrchestrator(
    owner~,
    resolver~,
    policy=@orchestration.ExecutionPolicy(enabled=true),
  )
}

///|
fn orch_handle(
  result : Result[
    @orchestration.ExecutionDispatch,
    @orchestration.OrchestrationError,
  ],
) -> @execution.BoardExecutionHandle raise {
  match result {
    Ok(@orchestration.Admitted(handle)) => handle
    _ => fail("expected exactly one admitted execution")
  }
}

///|
struct OrchJournal {
  mut records : Array[@execution.BoardExecutionBinding]
  mut writes : Int32
  fail_at : Int32
  visible_failure : Bool
  hold_at : Int32
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
fn orch_journal(
  fail_at~ : Int32 = -1,
  visible_failure~ : Bool = false,
  hold_at~ : Int32 = -1,
) -> OrchJournal {
  {
    records: [],
    writes: 0,
    fail_at,
    visible_failure,
    hold_at,
    entered: @aqueue.Queue(kind=Unbounded),
    release: @aqueue.Queue(kind=Unbounded),
  }
}

///|
impl @execution.BoardExecutionStore for OrchJournal with fn load(self) {
  Ok(self.records.copy())
}

///|
impl @execution.BoardExecutionStore for OrchJournal with fn persist(
  self,
  records,
) {
  self.writes += 1
  if self.writes == self.hold_at {
    self.entered.put(())
    self.release.get()
  }
  if self.writes == self.fail_at {
    if self.visible_failure {
      self.records = records.copy()
    }
    return Err(@execution.StoreUnavailable)
  }
  self.records = records.copy()
  Ok(())
}
