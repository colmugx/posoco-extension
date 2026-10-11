///|
struct RealAgentProbe {
  mut calls : Int
  mut stopped : Int
  scopes : Array[(String, String)]
  fail : Bool
  block : Bool
  entered : @aqueue.Queue[Unit]
  check : (async (String, String) -> Unit)?
}

///|
impl @posoco.Extension for RealAgentProbe with fn extension_id(_self) {
  "execution-test-model"
}

///|
impl @posoco.Extension for RealAgentProbe with fn manifest(self) {
  @posoco.ExtensionManifest::ExtensionManifest(
    id="execution-test-model",
    models=[self],
    lifecycle=[self],
  )
}

///|
impl @posoco.Lifecycle for RealAgentProbe with fn on_shutdown(self) {
  self.stopped += 1
}

///|
impl @posoco.ModelPort for RealAgentProbe with fn provider_config(_self) {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for RealAgentProbe with fn chat(
  self,
  scope,
  messages,
  _tools,
  _options,
  _stream,
) {
  self.calls += 1
  self.scopes.push((scope.session_id.to_string(), scope.run_id.to_string()))
  if self.check is Some(check) {
    check(scope.session_id.to_string(), scope.run_id.to_string()) catch {
      _ => raise @posoco.ModelError::Transport("barrier verification failed")
    }
  }
  ignore(self.entered.try_put(()) catch { _ => false })
  if self.block {
    @async.sleep(60000)
  }
  if self.fail {
    raise @posoco.ModelError::Transport("test failure")
  }
  {
    completion: @kernel.Completion::Completion(
      content=[@kernel.Text("done")],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
      usage=None,
    ),
    processed_messages: messages.to_owned(),
  }
}

///|
impl @posoco.ModelPort for RealAgentProbe with fn compact(
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
fn probe(
  fail? : Bool = false,
  block? : Bool = false,
  check? : (async (String, String) -> Unit)? = None,
) -> RealAgentProbe {
  {
    calls: 0,
    stopped: 0,
    scopes: [],
    fail,
    block,
    entered: @aqueue.Queue(kind=Unbounded),
    check,
  }
}

///|
async fn prepared_board(
  group : @async.TaskGroup[Unit],
  store? : &@store.BoardStore = @store.MemoryBoardStore(),
) -> @backend.BoardBackend {
  let backend = @backend.BoardBackend(store~, now_ms=() => 1234L)
  backend.attach(group)
  assert_true(backend.bootstrap_snapshot() is Ok(_))
  let create = backend.handle_command({
    command_id: "create",
    name: "board.task.create",
    expected_revision: 0L,
    args: {
      "id": "task",
      "title": "Explicit execution",
      "description": "",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    },
  })
  assert_true(create.accepted)
  let queue = backend.handle_command({
    command_id: "queue",
    name: "board.attempt.queue",
    expected_revision: 1L,
    args: { "id": "attempt", "task_id": "task", "kind": "execute" },
  })
  assert_true(queue.accepted)
  backend
}

///|
fn request(timeout? : Int? = None) -> @execution.BoardExecutionRequest {
  {
    task_id: "task",
    attempt_id: "attempt",
    execution_id: "exec",
    session_id: "session-exec",
    input: "Do explicit work",
    timeout_ms: timeout,
  }
}

///|
async test "real Posoco run owns scope gates effect and durably settles without task movement" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let store = @execution.MemoryBoardExecutionStore()
    let model = probe(
      check=Some((session, run) => {
        let recorded = store.load().unwrap()[0]
        assert_eq(recorded.phase, @execution.Running)
        assert_eq(recorded.run.unwrap().session_id, session)
        assert_eq(recorded.run.unwrap().run_id, run)
        assert_eq(backend.state().unwrap().attempts[0].status, @domain.Running)
      }),
    )
    let driver = @execution.PosocoBoardExecutionAdapter(extensions=() => [model])
    let owner = @execution.BoardExecutionOwner(backend~, adapter=driver, store~)
    assert_true(owner.attach(group) is Ok(_))
    let handle = match owner.execute(request()) {
      Ok(handle) => handle
      Err(_) => fail("admission")
    }
    let binding = handle.wait()
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Completed))
    assert_eq(model.calls, 1)
    assert_eq(model.stopped, 1)
    let run = match binding.run {
      Some(run) => run
      None => fail("missing actual scope")
    }
    assert_eq(model.scopes[0], (run.session_id, run.run_id))
    let state = match backend.state() {
      Ok(state) => state
      Err(_) => fail("state")
    }
    assert_eq(state.revision, 4L)
    assert_eq(state.tasks[0].stage, @domain.Created)
    assert_eq(state.attempts[0].status, @domain.Succeeded)
    assert_eq(state.attempts[0].started_at_ms, Some(1234L))
    assert_eq(state.attempts[0].finished_at_ms, Some(1234L))
    assert_eq(state.attempts[0].review, None)
    assert_true(owner.execute(request()) is Err(@execution.DuplicateIdentity))
    let events = backend.event_history()
    assert_eq(
      events.filter(event => event.kind == "board.attempt.started").length(),
      1,
    )
    assert_eq(
      events.filter(event => event.kind == "board.attempt.finished").length(),
      1,
    )
    assert_eq(
      events.filter(event => event.kind == "execution.started").length(),
      1,
    )
    assert_false(
      events.any(event => event.payload.stringify().contains("Do explicit work")),
    )
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "real Posoco failure and timeout await shutdown before durable attempt termination" {
  for timed_out in [false, true] {
    @async.with_task_group(group => {
      let backend = prepared_board(group)
      let model = probe(fail=!timed_out, block=timed_out)
      let driver = @execution.PosocoBoardExecutionAdapter(extensions=() => {
        [model]
      })
      let owner = @execution.BoardExecutionOwner(
        backend~,
        adapter=driver,
        store=@execution.MemoryBoardExecutionStore(),
      )
      assert_true(owner.attach(group) is Ok(_))
      let handle = match
        owner.execute(request(timeout=if timed_out { Some(100) } else { None })) {
        Ok(handle) => handle
        Err(_) => fail("admission")
      }
      let binding = handle.wait()
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(
        binding.outcome,
        Some(if timed_out { @execution.TimedOut } else { @execution.Failed }),
      )
      assert_eq(model.stopped, 1)
      let state = match backend.state() {
        Ok(value) => value
        Err(_) => fail("state")
      }
      assert_eq(
        state.attempts[0].status,
        if timed_out {
          @domain.Interrupted
        } else {
          @domain.Failed
        },
      )
      assert_true(owner.shutdown())
      backend.shutdown()
    })
  }
}

///|
async test "real scoped cancellation targets owner identity and waits for Agent cleanup" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let model = probe(block=true)
    let driver = @execution.PosocoBoardExecutionAdapter(extensions=() => [model])
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=@execution.MemoryBoardExecutionStore(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let handle = match owner.execute(request()) {
      Ok(handle) => handle
      Err(_) => fail("admission")
    }
    model.entered.get()
    assert_true(owner.cancel("unrelated") is Err(@execution.WrongExecution))
    assert_true(owner.cancel("exec") is Ok(_))
    assert_true(owner.cancel("exec") is Ok(_))
    let binding = handle.wait()
    assert_eq(model.stopped, 1)
    assert_eq(binding.outcome, Some(@execution.Cancelled))
    assert_eq(binding.phase, @execution.Settled)
    assert_true(owner.cancel("exec") is Ok(_))
    let state = match backend.state() {
      Ok(value) => value
      Err(_) => fail("state")
    }
    assert_eq(state.attempts[0].status, @domain.Cancelled)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "Posoco false gate prevents provider invocation and still joins scoped Agent" {
  let model = probe()
  let driver = @execution.PosocoBoardExecutionAdapter(extensions=() => [model])
  let seen = Ref(false)
  let outcome = driver.run(request(), scope => {
    assert_eq(scope.session_id, "session-exec")
    seen.val = true
    false
  })
  assert_true(seen.val)
  assert_eq(model.calls, 0)
  assert_eq(model.stopped, 1)
  assert_true(outcome != @execution.Completed)
}
