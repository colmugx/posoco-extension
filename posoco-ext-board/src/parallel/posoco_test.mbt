///|
/// Real Posoco Agent composition: one multi-slot owner drives actually
/// overlapping, independently scoped Agent lifetimes (real `run_scoped`/
/// `run_turn` identity) through deterministic ModelPorts. No network, no live
/// provider and no tool side effect is involved or claimed.

///|
/// Deterministic ModelPort probe. It records the actual scoped identity and
/// the exact input that reached the model, and can fail or hold until
/// released for failure, timeout and cancellation scenarios.
struct ParallelRealModel {
  mut calls : Int32
  mut stopped : Int32
  scopes : Array[(String, String)]
  inputs : Array[String]
  fail : Bool
  hold : Bool
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
fn parallel_real_model(
  fail~ : Bool = false,
  hold~ : Bool = false,
) -> ParallelRealModel {
  {
    calls: 0,
    stopped: 0,
    scopes: [],
    inputs: [],
    fail,
    hold,
    entered: @aqueue.Queue(kind=Unbounded),
    release: @aqueue.Queue(kind=Unbounded),
  }
}

///|
/// Joins the explicit user text that reached the model.
fn parallel_real_input(messages : ArrayView[@kernel.Message]) -> String {
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
impl @posoco.Extension for ParallelRealModel with fn extension_id(_self) {
  "parallel-test-model"
}

///|
impl @posoco.Extension for ParallelRealModel with fn manifest(self) {
  @posoco.ExtensionManifest::ExtensionManifest(
    id="parallel-test-model",
    models=[self],
    lifecycle=[self],
  )
}

///|
impl @posoco.Lifecycle for ParallelRealModel with fn on_shutdown(self) {
  self.stopped += 1
}

///|
impl @posoco.ModelPort for ParallelRealModel with fn provider_config(_self) {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for ParallelRealModel with fn chat(
  self,
  scope,
  messages,
  _tools,
  _options,
  _stream,
) {
  self.calls += 1
  self.scopes.push((scope.session_id.to_string(), scope.run_id.to_string()))
  self.inputs.push(parallel_real_input(messages))
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
      content=[@kernel.Text("parallel settle complete")],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
      usage=None,
    ),
    processed_messages: messages.to_owned(),
  }
}

///|
impl @posoco.ModelPort for ParallelRealModel with fn compact(
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
struct ParallelRealHarness {
  backend : @backend.BoardBackend
  owner : @execution.BoardExecutionOwner
  resolver : ParallelResolver
  runner : @parallel.ParallelWorkflowRunner
  models : Array[ParallelRealModel]
}

///|
/// One two-slot owner whose factory hands slot N its own dedicated Agent
/// driver over models[N]; every slot therefore constructs and owns a fresh
/// Agent per run, exactly like a real host composition.
async fn parallel_real_harness(
  group : @async.TaskGroup[Unit],
  tasks~ : Array[String],
  models~ : Array[ParallelRealModel],
  resolver~ : ParallelResolver,
) -> ParallelRealHarness {
  let backend = parallel_board(group, tasks~)
  let cursor = [0]
  let owner = @execution.BoardExecutionOwner::with_slots(
    backend~,
    store=@execution.MemoryBoardExecutionStore(),
    adapter_factory=_ => {
      let slot = cursor[0]
      cursor[0] = slot + 1
      let model = match models.get(slot) {
        Some(model) => model
        None => parallel_real_model()
      }
      @execution.PosocoBoardExecutionAdapter(extensions=() => [model])
    },
    max_concurrency=2,
  ).unwrap()
  assert_true(owner.attach(group) is Ok(_))
  let orchestrator = @orchestration.BoardOrchestrator(
    owner~,
    resolver~,
    policy=@orchestration.ExecutionPolicy(enabled=true),
  )
  let runner = @parallel.ParallelWorkflowRunner(orchestrator~, group~)
  { backend, owner, resolver, runner, models, }
}

///|
async test "two real agents run simultaneously with independent scopes" {
  @async.with_task_group(group => {
    let models = [
      parallel_real_model(hold=true),
      parallel_real_model(hold=true),
    ]
    let resolver = parallel_resolver(available=[
      "alpha/attempt-alpha-1", "beta/attempt-beta-1",
    ])
    let h = parallel_real_harness(
      group,
      tasks=["alpha", "beta"],
      models~,
      resolver~,
    )
    assert_true(
      h.runner.start(parallel_spec(run_id="board-run-1", max_concurrency=2))
      is Ok(_),
    )
    // Both dedicated Agents are inside their turns at the same time.
    parallel_yield_until(what="two real turns", check=() => {
      h.models[0].calls == 1 && h.models[1].calls == 1
    })
    let active = h.runner.status()
    assert_eq(active.phase, @workflow.Running)
    assert_eq(active.active_count, 2)
    assert_eq(active.available_slots, 0)
    assert_eq(h.owner.status().active_bindings.length(), 2)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    // Each Agent turn observed exactly its own dedicated session and run
    // identity; command IDs never became execution identity. Fresh-ID
    // re-authorization can add earlier pre-admission records, so the input is
    // matched against the exact authorization bound to this execution.
    for index in 0..<2 {
      assert_eq(h.models[index].scopes.length(), 1)
      assert_eq(h.models[index].scopes[0].0, bindings[index].session_id)
      assert_eq(
        h.models[index].scopes[0].1,
        bindings[index].run.unwrap().run_id,
      )
      let record = h.resolver.authorization_index(bindings[index].execution_id)
      assert_eq(h.models[index].inputs[0], h.resolver.inputs[record])
      assert_eq(h.models[index].scopes[0].0, h.resolver.session_ids[record])
    }
    assert_false(bindings[0].execution_id == bindings[1].execution_id)
    assert_false(bindings[0].session_id == bindings[1].session_id)
    assert_false(h.models[0].scopes[0].0 == h.models[1].scopes[0].0)
    h.models[0].release.put(())
    h.models[1].release.put(())
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.succeeded, 2)
    assert_eq(h.models[0].stopped, 1)
    assert_eq(h.models[1].stopped, 1)
    for binding in h.owner.bindings() {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.Completed))
    }
    // The durable Board never sees the ephemeral input or model output.
    for payload in parallel_event_payloads(h.backend) {
      assert_false(payload.contains("explicit parallel input"))
      assert_false(payload.contains("parallel settle complete"))
    }
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a real agent failure stops the wave under the default policy" {
  @async.with_task_group(group => {
    // The failing Agent holds its turn too, so both dedicated Agents are
    // inside their turns before the failure is released; an instant failure
    // would legitimately withdraw beta's admission instead of proving the
    // wave containment.
    let models = [
      parallel_real_model(fail=true, hold=true),
      parallel_real_model(hold=true),
    ]
    let resolver = parallel_resolver(available=[
      "alpha/attempt-alpha-1", "beta/attempt-beta-1", "gamma/attempt-gamma-1",
    ])
    let h = parallel_real_harness(
      group,
      tasks=["alpha", "beta", "gamma"],
      models~,
      resolver~,
    )
    assert_true(
      h.runner.start(parallel_spec(run_id="board-run-2", max_concurrency=2))
      is Ok(_),
    )
    parallel_yield_until(what="two real turns", check=() => {
      h.models[0].calls == 1 && h.models[1].calls == 1
    })
    // Deterministic releases: the failure settles first, then the unaffected
    // sibling completes normally and the wave ends after both confirm.
    h.models[0].release.put(())
    h.models[1].release.put(())
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Failed)
    assert_eq(status.reason, Some(@workflow.ExecutionFailed(@execution.Failed)))
    assert_eq(status.failed, 1)
    assert_eq(status.succeeded, 1)
    assert_eq(h.models[0].calls, 1)
    assert_eq(h.models[1].calls, 1)
    assert_eq(h.models[0].stopped, 1)
    // gamma was never admitted after the confirmed failure.
    assert_false(h.resolver.resolved_attempts.contains("attempt-gamma-1"))
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[0].phase, @execution.Settled)
    assert_eq(bindings[0].outcome, Some(@execution.Failed))
    assert_eq(bindings[1].attempt_id, "attempt-beta-1")
    assert_eq(bindings[1].phase, @execution.Settled)
    assert_eq(bindings[1].outcome, Some(@execution.Completed))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "the real execution timeout settles both held agents as TimedOut" {
  @async.with_task_group(group => {
    let models = [
      parallel_real_model(hold=true),
      parallel_real_model(hold=true),
    ]
    let resolver = parallel_resolver(available=[
      "alpha/attempt-alpha-1", "beta/attempt-beta-1",
    ])
    let h = parallel_real_harness(
      group,
      tasks=["alpha", "beta"],
      models~,
      resolver~,
    )
    assert_true(
      h.runner.start(
        parallel_spec(
          run_id="board-run-3",
          max_concurrency=2,
          max_elapsed_ms=5000,
          execution_timeout_ms=100,
        ),
      )
      is Ok(_),
    )
    parallel_yield_until(what="two held turns", check=() => {
      h.models[0].calls == 1 && h.models[1].calls == 1
    })
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Failed)
    assert_eq(
      status.reason,
      Some(@workflow.ExecutionFailed(@execution.TimedOut)),
    )
    assert_eq(status.failed, 2)
    assert_eq(h.models[0].calls, 1)
    assert_eq(h.models[1].calls, 1)
    for binding in h.owner.bindings() {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.TimedOut))
    }
    // Each timed-out Board Attempt is Interrupted, not silently successful.
    for attempt in h.backend.state().unwrap().attempts {
      assert_eq(attempt.status, @domain.Interrupted)
    }
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "cancel during real held agents settles both as cancelled" {
  @async.with_task_group(group => {
    let models = [
      parallel_real_model(hold=true),
      parallel_real_model(hold=true),
    ]
    let resolver = parallel_resolver(available=[
      "alpha/attempt-alpha-1", "beta/attempt-beta-1",
    ])
    let h = parallel_real_harness(
      group,
      tasks=["alpha", "beta"],
      models~,
      resolver~,
    )
    assert_true(
      h.runner.start(parallel_spec(run_id="board-run-4", max_concurrency=2))
      is Ok(_),
    )
    parallel_yield_until(what="two held turns", check=() => {
      h.models[0].calls == 1 && h.models[1].calls == 1
    })
    h.runner.cancel()
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(status.reason, Some(@workflow.CancelRequested))
    assert_eq(status.cancelled, 2)
    assert_eq(status.succeeded, 0)
    for binding in h.owner.bindings() {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.Cancelled))
    }
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
