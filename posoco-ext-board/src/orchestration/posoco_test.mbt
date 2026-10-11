///|
/// Actual `BoardOrchestrator` integration: one explicit dispatch drives a real,
/// exclusively owned Posoco Agent (actual `run_scoped`/`run_turn` identity and
/// lifecycle) against an online Board through the opt-in execution owner. The
/// model is a deterministic ModelPort: there is no network, no live provider
/// and no tool side effect, and no live-provider behavior is claimed. The
/// trusted host supplies input through the typed `BoardExecutionInputResolver`
/// trait; every resolve allocates fresh session/execution identities that are
/// independent of Board command IDs and carries explicit ephemeral input that
/// must reach the model but never any durable Board event.

///|
/// Deterministic ModelPort probe. It records the actual scoped identity and the
/// exact input that reached the model, can verify durable owner/Board state at
/// the model gate, and can fail or hold until released for timeout and
/// cancellation scenarios.
struct RealOrchestrationModel {
  mut calls : Int
  mut stopped : Int
  scopes : Array[(String, String)]
  inputs : Array[String]
  fail : Bool
  hold : Bool
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  mut check : (async (String, String) -> Unit)?
}

///|
fn real_model(
  fail? : Bool = false,
  hold? : Bool = false,
) -> RealOrchestrationModel {
  {
    calls: 0,
    stopped: 0,
    scopes: [],
    inputs: [],
    fail,
    hold,
    entered: @aqueue.Queue(kind=Unbounded),
    release: @aqueue.Queue(kind=Unbounded),
    check: None,
  }
}

///|
/// Joins the explicit user text that reached the model.
fn real_model_input(messages : ArrayView[@kernel.Message]) -> String {
  let texts : Array[String] = []
  for index in 0..<messages.length() {
    match messages[index] {
      @kernel.UserMessage(content~) =>
        for block in content {
          match block {
            @kernel.Text(value) => texts.push(value)
            _ => ()
          }
        }
      _ => ()
    }
  }
  texts.join("\n")
}

///|
impl @posoco.Extension for RealOrchestrationModel with fn extension_id(_self) {
  "orchestration-test-model"
}

///|
impl @posoco.Extension for RealOrchestrationModel with fn manifest(self) {
  @posoco.ExtensionManifest::ExtensionManifest(
    id="orchestration-test-model",
    models=[self],
    lifecycle=[self],
  )
}

///|
impl @posoco.Lifecycle for RealOrchestrationModel with fn on_shutdown(self) {
  self.stopped += 1
}

///|
impl @posoco.ModelPort for RealOrchestrationModel with fn provider_config(_self) {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for RealOrchestrationModel with fn chat(
  self,
  scope,
  messages,
  _tools,
  _options,
  _stream,
) {
  self.calls += 1
  self.scopes.push((scope.session_id.to_string(), scope.run_id.to_string()))
  self.inputs.push(real_model_input(messages))
  if self.check is Some(check) {
    check(scope.session_id.to_string(), scope.run_id.to_string()) catch {
      _ => raise @posoco.ModelError::Transport("barrier verification failed")
    }
  }
  self.entered.put(()) catch {
    _ => ()
  }
  if self.hold {
    self.release.get() catch {
      _ => ()
    }
  }
  if self.fail {
    raise @posoco.ModelError::Transport("test failure")
  }
  {
    completion: @kernel.Completion::Completion(
      content=[@kernel.Text("orchestration settle complete")],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
      usage=None,
    ),
    processed_messages: messages.to_owned(),
  }
}

///|
impl @posoco.ModelPort for RealOrchestrationModel with fn compact(
  _self,
  _scope,
  _messages,
  _tools,
  _options,
  _trigger,
) {
  raise @posoco.ModelError::Transport("compact not expected")
}

///|
/// Trusted host resolver behind the typed `BoardExecutionInputResolver` trait.
/// Availability is synchronous metadata; resolve allocates a fresh, dedicated
/// execution/session identity per call, independent of Board command IDs, with
/// explicit ephemeral input and an optional host timeout.
struct RealHostResolver {
  available : Array[String]
  timeout_ms : Int?
  mut seq : Int
  execution_ids : Array[String]
  session_ids : Array[String]
  inputs : Array[String]
}

///|
fn real_resolver(
  available~ : Array[String],
  timeout_ms? : Int? = None,
) -> RealHostResolver {
  {
    available,
    timeout_ms,
    seq: 0,
    execution_ids: [],
    session_ids: [],
    inputs: [],
  }
}

///|
impl @orchestration.BoardExecutionInputResolver for RealHostResolver with fn availability(
  self,
  candidate,
) {
  if self.available.contains("\{candidate.task_id}/\{candidate.attempt_id}") {
    @orchestration.Available
  } else {
    @orchestration.Missing
  }
}

///|
impl @orchestration.BoardExecutionInputResolver for RealHostResolver with fn resolve(
  self,
  _candidate,
) {
  self.seq += 1
  let execution_id = "exec-\{self.seq}"
  let session_id = "session-\{self.seq}"
  let input = "explicit orchestration input \{self.seq}"
  self.execution_ids.push(execution_id)
  self.session_ids.push(session_id)
  self.inputs.push(input)
  @orchestration.Authorized({
    execution_id,
    session_id,
    input,
    timeout_ms: self.timeout_ms,
  })
}

///|
/// Online Board through real commands only: one Ready task with queued Execute
/// Attempts. The command IDs below are correlation data and never become
/// execution or session identity.
async fn real_ready_board(
  group : @async.TaskGroup[Unit],
  attempts? : Int = 1,
) -> @backend.BoardBackend {
  let backend = @backend.BoardBackend(store=@store.MemoryBoardStore(), now_ms=() => {
    1234L
  })
  backend.attach(group)
  assert_true(backend.bootstrap_snapshot() is Ok(_))
  assert_true(
    backend.handle_command({
      command_id: "create",
      name: "board.task.create",
      expected_revision: 0L,
      args: {
        "id": "task",
        "title": "Ready execution task",
        "description": "",
        "priority": "normal",
        "definition_of_done": [],
        "dependencies": [],
      },
    }).accepted,
  )
  assert_true(
    backend.handle_command({
      command_id: "to-refining",
      name: "board.task.move",
      expected_revision: 1L,
      args: { "id": "task", "to": "refining" },
    }).accepted,
  )
  assert_true(
    backend.handle_command({
      command_id: "to-ready",
      name: "board.task.move",
      expected_revision: 2L,
      args: { "id": "task", "to": "ready" },
    }).accepted,
  )
  for index in 1..<=attempts {
    assert_true(
      backend.handle_command({
        command_id: "queue-\{index}",
        name: "board.attempt.queue",
        expected_revision: (2 + index).to_int64(),
        args: { "id": "attempt-\{index}", "task_id": "task", "kind": "execute" },
      }).accepted,
    )
  }
  let state = backend.state().unwrap()
  assert_eq(state.tasks[0].stage, @domain.Ready)
  assert_eq(state.attempts.length(), attempts)
  backend
}

///|
/// One owner (attached to the host group) with the actual Posoco driver and the
/// trusted host resolver behind an enabled Ready-stage policy.
async fn real_orchestrator(
  group : @async.TaskGroup[Unit],
  backend : @backend.BoardBackend,
  model : RealOrchestrationModel,
  resolver : RealHostResolver,
) -> (@execution.BoardExecutionOwner, @orchestration.BoardOrchestrator) {
  let driver = @execution.PosocoBoardExecutionAdapter(extensions=() => [model])
  let owner = @execution.BoardExecutionOwner(
    backend~,
    adapter=driver,
    store=@execution.MemoryBoardExecutionStore(),
  )
  assert_true(owner.attach(group) is Ok(_))
  let orchestrator = @orchestration.BoardOrchestrator(
    owner~,
    resolver~,
    policy=@orchestration.ExecutionPolicy(enabled=true),
  )
  (owner, orchestrator)
}

///|
async test "real orchestrator dispatch settles one scoped Agent run durably without moving the Ready task" {
  @async.with_task_group(group => {
    let backend = real_ready_board(group)
    let model = real_model()
    let resolver = real_resolver(available=["task/attempt-1"])
    let (owner, orchestrator) = real_orchestrator(
      group, backend, model, resolver,
    )
    let plan = orchestrator.plan().unwrap()
    assert_eq(plan.revision, 4L)
    assert_eq(plan.eligible.length(), 1)
    assert_eq(plan.eligible[0].task_id, "task")
    assert_eq(plan.eligible[0].attempt_id, "attempt-1")
    let status = orchestrator.status().unwrap()
    assert_true(status.admission_enabled)
    assert_false(status.dispatch_busy)
    assert_eq(status.plan.eligible[0].attempt_id, "attempt-1")
    // The actual Agent may only reach the provider after the durable gate.
    model.check = Some((session, run) => {
      let recorded = owner.bindings()
      assert_eq(recorded.length(), 1)
      assert_eq(recorded[0].phase, @execution.Running)
      assert_eq(recorded[0].execution_id, resolver.execution_ids[0])
      assert_eq(recorded[0].session_id, resolver.session_ids[0])
      assert_eq(session, resolver.session_ids[0])
      assert_eq(recorded[0].run.unwrap().session_id, session)
      assert_eq(recorded[0].run.unwrap().run_id, run)
      assert_eq(backend.state().unwrap().attempts[0].status, @domain.Running)
    })
    let handle = match orchestrator.dispatch_next().unwrap() {
      @orchestration.Admitted(handle) => handle
      _ => fail("expected exactly one admitted execution")
    }
    model.entered.get()
    let binding = handle.wait()
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Completed))
    assert_eq(model.calls, 1)
    assert_eq(model.stopped, 1)
    assert_eq(binding.execution_id, resolver.execution_ids[0])
    assert_eq(binding.session_id, resolver.session_ids[0])
    let (session, run) = model.scopes[0]
    let actual = binding.run.unwrap()
    assert_eq(model.scopes[0], (actual.session_id, actual.run_id))
    assert_eq(session, actual.session_id)
    assert_eq(run, actual.run_id)
    assert_true(model.inputs[0].contains("explicit orchestration input 1"))
    for command in ["create", "to-refining", "to-ready", "queue-1"] {
      assert_false(binding.execution_id == command)
      assert_false(binding.session_id == command)
    }
    let state = backend.state().unwrap()
    assert_eq(state.revision, 6L)
    assert_eq(state.tasks[0].stage, @domain.Ready)
    assert_eq(state.tasks[0].ready_since_ms, Some(1234L))
    assert_eq(state.attempts[0].status, @domain.Succeeded)
    assert_eq(state.attempts[0].review, None)
    assert_eq(state.attempts[0].started_at_ms, Some(1234L))
    assert_eq(state.attempts[0].finished_at_ms, Some(1234L))
    let bindings = owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].phase, @execution.Settled)
    assert_eq(bindings[0].outcome, Some(@execution.Completed))
    let events = backend.event_history()
    assert_eq(
      events.filter(event => event.kind == "board.attempt.started").length(),
      1,
    )
    assert_eq(
      events.filter(event => event.kind == "board.attempt.finished").length(),
      1,
    )
    let started = events.filter(event => event.kind == "execution.started")
    assert_eq(started.length(), 1)
    assert_eq(started[0].scope.unwrap().session_id, Some(actual.session_id))
    assert_eq(started[0].scope.unwrap().run_id, Some(actual.run_id))
    for event in events {
      let payload = event.payload.stringify()
      assert_false(payload.contains("explicit orchestration input"))
      assert_false(payload.contains("orchestration settle complete"))
    }
    // No automatic next: the spent attempt never dispatches again.
    assert_true(
      orchestrator.dispatch_next().unwrap() is @orchestration.Blocked(_),
    )
    assert_true(orchestrator.shutdown())
    backend.shutdown()
  })
}

///|
async test "two queued attempts get one explicit dispatch each with fresh host identity and no automatic next" {
  @async.with_task_group(group => {
    let backend = real_ready_board(group, attempts=2)
    let model = real_model(hold=true)
    let resolver = real_resolver(available=["task/attempt-1", "task/attempt-2"])
    let (owner, orchestrator) = real_orchestrator(
      group, backend, model, resolver,
    )
    // Multiple queued attempts do not create parallel slots.
    let plan = orchestrator.plan().unwrap()
    assert_eq(plan.eligible.length(), 1)
    assert_eq(plan.blocked.length(), 0)
    assert_eq(plan.eligible[0].attempt_id, "attempt-1")
    let handle = match orchestrator.dispatch_next().unwrap() {
      @orchestration.Admitted(handle) => handle
      _ => fail("expected the oldest queued attempt to be admitted")
    }
    model.entered.get()
    assert_eq(
      orchestrator.status().unwrap().owner.active.unwrap().attempt_id,
      "attempt-1",
    )
    match orchestrator.dispatch_next().unwrap() {
      @orchestration.Blocked(blocked) => {
        assert_eq(blocked.eligible.length(), 0)
        assert_eq(blocked.blocked.length(), 1)
        assert_true(
          blocked.blocked[0].reasons.contains(@orchestration.ExecutionActive),
        )
      }
      _ => fail("an active run must block any further dispatch")
    }
    assert_eq(model.calls, 1)
    model.release.put(())
    let first = handle.wait()
    assert_eq(first.phase, @execution.Settled)
    assert_eq(first.outcome, Some(@execution.Completed))
    let between = backend.state().unwrap()
    assert_eq(between.tasks[0].stage, @domain.Ready)
    assert_eq(between.attempts[0].status, @domain.Succeeded)
    assert_eq(between.attempts[1].status, @domain.Queued)
    assert_eq(between.attempts[1].review, None)
    assert_eq(model.calls, 1)
    assert_eq(orchestrator.plan().unwrap().eligible[0].attempt_id, "attempt-2")
    model.release.put(())
    let second = match orchestrator.dispatch_next().unwrap() {
      @orchestration.Admitted(handle) => handle
      _ => fail("expected the explicit second dispatch to progress")
    }
    model.entered.get()
    let settled = second.wait()
    assert_eq(settled.phase, @execution.Settled)
    assert_eq(settled.outcome, Some(@execution.Completed))
    assert_eq(model.calls, 2)
    assert_eq(model.stopped, 2)
    assert_eq(resolver.execution_ids.length(), 2)
    assert_false(resolver.execution_ids[0] == resolver.execution_ids[1])
    assert_false(resolver.session_ids[0] == resolver.session_ids[1])
    for index in 0..<resolver.execution_ids.length() {
      for command in ["create", "to-refining", "to-ready", "queue-1", "queue-2"] {
        assert_false(resolver.execution_ids[index] == command)
        assert_false(resolver.session_ids[index] == command)
      }
    }
    assert_true(model.inputs[0].contains("explicit orchestration input 1"))
    assert_true(model.inputs[1].contains("explicit orchestration input 2"))
    let bindings = owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_false(bindings[0].session_id == bindings[1].session_id)
    assert_eq(bindings[1].attempt_id, "attempt-2")
    let after = backend.state().unwrap()
    assert_eq(after.revision, 9L)
    assert_eq(after.tasks[0].stage, @domain.Ready)
    assert_eq(after.attempts[1].status, @domain.Succeeded)
    assert_eq(after.attempts[1].review, None)
    assert_true(orchestrator.shutdown())
    backend.shutdown()
  })
}

///|
async test "real orchestrator settles a model failure as Failed and leaves the Ready task untouched" {
  @async.with_task_group(group => {
    let backend = real_ready_board(group)
    let model = real_model(fail=true)
    let resolver = real_resolver(available=["task/attempt-1"])
    let (owner, orchestrator) = real_orchestrator(
      group, backend, model, resolver,
    )
    let handle = match orchestrator.dispatch_next().unwrap() {
      @orchestration.Admitted(handle) => handle
      _ => fail("expected exactly one admitted execution")
    }
    model.entered.get()
    let binding = handle.wait()
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Failed))
    assert_eq(model.calls, 1)
    assert_eq(model.stopped, 1)
    let state = backend.state().unwrap()
    assert_eq(state.revision, 6L)
    assert_eq(state.tasks[0].stage, @domain.Ready)
    assert_eq(state.attempts[0].status, @domain.Failed)
    assert_eq(state.attempts[0].review, None)
    assert_eq(owner.bindings()[0].outcome, Some(@execution.Failed))
    assert_true(orchestrator.shutdown())
    backend.shutdown()
  })
}

///|
async test "host resolver timeout settles the active run as TimedOut with an Interrupted attempt" {
  @async.with_task_group(group => {
    let backend = real_ready_board(group)
    let model = real_model(hold=true)
    let resolver = real_resolver(
      available=["task/attempt-1"],
      timeout_ms=Some(100),
    )
    let (owner, orchestrator) = real_orchestrator(
      group, backend, model, resolver,
    )
    let handle = match orchestrator.dispatch_next().unwrap() {
      @orchestration.Admitted(handle) => handle
      _ => fail("expected exactly one admitted execution")
    }
    model.entered.get()
    let binding = handle.wait()
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.TimedOut))
    assert_eq(model.calls, 1)
    assert_eq(model.stopped, 1)
    let state = backend.state().unwrap()
    assert_eq(state.tasks[0].stage, @domain.Ready)
    assert_eq(state.attempts[0].status, @domain.Interrupted)
    assert_eq(state.attempts[0].review, None)
    assert_eq(owner.bindings()[0].outcome, Some(@execution.TimedOut))
    assert_true(orchestrator.shutdown())
    backend.shutdown()
  })
}

///|
async test "exact execution identity cancels the scoped run while wrong and repeated requests stay harmless" {
  @async.with_task_group(group => {
    let backend = real_ready_board(group)
    let model = real_model(hold=true)
    let resolver = real_resolver(available=["task/attempt-1"])
    let (owner, orchestrator) = real_orchestrator(
      group, backend, model, resolver,
    )
    let handle = match orchestrator.dispatch_next().unwrap() {
      @orchestration.Admitted(handle) => handle
      _ => fail("expected exactly one admitted execution")
    }
    model.entered.get()
    assert_true(
      orchestrator.cancel_active("unrelated") is Err(@execution.WrongExecution),
    )
    // The session identity is not the execution identity.
    assert_true(
      orchestrator.cancel_active(resolver.session_ids[0])
      is Err(@execution.WrongExecution),
    )
    assert_true(orchestrator.cancel_active(resolver.execution_ids[0]) is Ok(_))
    assert_true(orchestrator.cancel_active(resolver.execution_ids[0]) is Ok(_))
    let binding = handle.wait()
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Cancelled))
    assert_eq(model.calls, 1)
    assert_eq(model.stopped, 1)
    let state = backend.state().unwrap()
    assert_eq(state.tasks[0].stage, @domain.Ready)
    assert_eq(state.attempts[0].status, @domain.Cancelled)
    assert_eq(state.attempts[0].review, None)
    assert_eq(owner.bindings()[0].outcome, Some(@execution.Cancelled))
    assert_true(orchestrator.cancel_active(resolver.execution_ids[0]) is Ok(_))
    assert_true(orchestrator.shutdown())
    backend.shutdown()
  })
}

///|
async test "orchestrator shutdown while active cancels joins and settles before closing admission" {
  @async.with_task_group(group => {
    let backend = real_ready_board(group)
    let model = real_model(hold=true)
    let resolver = real_resolver(available=["task/attempt-1"])
    let (owner, orchestrator) = real_orchestrator(
      group, backend, model, resolver,
    )
    let handle = match orchestrator.dispatch_next().unwrap() {
      @orchestration.Admitted(handle) => handle
      _ => fail("expected exactly one admitted execution")
    }
    model.entered.get()
    assert_eq(
      orchestrator.status().unwrap().owner.active.unwrap().execution_id,
      resolver.execution_ids[0],
    )
    assert_true(orchestrator.shutdown())
    let binding = handle.wait()
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Cancelled))
    assert_eq(model.calls, 1)
    assert_eq(model.stopped, 1)
    assert_eq(owner.bindings()[0].outcome, Some(@execution.Cancelled))
    let state = backend.state().unwrap()
    assert_eq(state.tasks[0].stage, @domain.Ready)
    assert_eq(state.attempts[0].status, @domain.Cancelled)
    assert_eq(state.attempts[0].review, None)
    assert_true(orchestrator.dispatch_next() is Err(@orchestration.Closed))
    let status = orchestrator.status().unwrap()
    assert_false(status.admission_enabled)
    assert_true(status.owner.closed)
    assert_true(
      status.plan.blocked[0].reasons.contains(@orchestration.OwnerClosed),
    )
    assert_true(orchestrator.shutdown())
    backend.shutdown()
  })
}
