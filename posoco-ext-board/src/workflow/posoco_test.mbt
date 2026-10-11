///|
/// Actual `SequentialWorkflowRunner` integration: one explicit host
/// authorization sequences real, exclusively owned Posoco Agents (actual
/// `run_scoped`/`run_turn` identity and lifecycle) through the S4B
/// orchestrator and the opt-in execution owner. The model is a deterministic
/// ModelPort: there is no network, no live provider and no tool side effect,
/// and no live-provider behavior is claimed. The trusted host supplies input
/// through the typed `BoardExecutionInputResolver` trait; every resolve
/// allocates fresh session/execution identities that are independent of Board
/// command IDs and carries explicit ephemeral input that must reach the model
/// but never any durable Board event.

///|
/// Deterministic ModelPort probe. It records the actual scoped identity and
/// the exact input that reached the model, and can fail or hold until
/// released for failure, cancellation and pause scenarios.
struct WorkflowRealModel {
  mut calls : Int
  mut stopped : Int
  mut settled_before_next : () -> Bool
  scopes : Array[(String, String)]
  inputs : Array[String]
  fail : Bool
  hold : Bool
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
fn workflow_real_model(
  fail? : Bool = false,
  hold? : Bool = false,
) -> WorkflowRealModel {
  {
    calls: 0,
    stopped: 0,
    settled_before_next: () => true,
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
fn workflow_real_model_input(messages : ArrayView[@kernel.Message]) -> String {
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
impl @posoco.Extension for WorkflowRealModel with fn extension_id(_self) {
  "workflow-test-model"
}

///|
impl @posoco.Extension for WorkflowRealModel with fn manifest(self) {
  @posoco.ExtensionManifest::ExtensionManifest(
    id="workflow-test-model",
    models=[self],
    lifecycle=[self],
  )
}

///|
impl @posoco.Lifecycle for WorkflowRealModel with fn on_shutdown(self) {
  self.stopped += 1
}

///|
impl @posoco.ModelPort for WorkflowRealModel with fn provider_config(_self) {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for WorkflowRealModel with fn chat(
  self,
  scope,
  messages,
  _tools,
  _options,
  _stream,
) {
  if self.calls != self.stopped ||
    (self.calls > 0 && !(self.settled_before_next)()) {
    raise @posoco.ModelError::Transport(
      "previous test execution was not joined and settled",
    )
  }
  self.calls += 1
  self.scopes.push((scope.session_id.to_string(), scope.run_id.to_string()))
  self.inputs.push(workflow_real_model_input(messages))
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
      content=[@kernel.Text("workflow settle complete")],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
      usage=None,
    ),
    processed_messages: messages.to_owned(),
  }
}

///|
impl @posoco.ModelPort for WorkflowRealModel with fn compact(
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
/// One owner (attached to the host group) with the actual Posoco driver, the
/// scripted trusted host resolver and an enabled Ready-stage policy, wired
/// into one runner inside the same structured host lifetime.
async fn workflow_real_harness(
  group : @async.TaskGroup[Unit],
  tasks~ : Array[String],
  model~ : WorkflowRealModel,
  resolver~ : ScriptedResolver,
) -> WorkflowHarness {
  let backend = workflow_board(group, tasks~)
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
  let runner = @workflow.SequentialWorkflowRunner(orchestrator~, group~)
  let adapter = scripted_adapter()
  {
    backend,
    owner,
    orchestrator,
    adapter,
    resolver,
    runner,
    clock: fake_clock(),
  }
}

///|
async test "the runner sequences two real scoped agent turns without parallelism" {
  @async.with_task_group(group => {
    let model = workflow_real_model()
    let resolver = scripted_resolver(available=[
      "alpha/attempt-alpha-1", "beta/attempt-beta-1",
    ])
    let h = workflow_real_harness(
      group,
      tasks=["alpha", "beta"],
      model~,
      resolver~,
    )
    model.settled_before_next = () => {
      let records = h.owner.bindings()
      records.length() >= 2 && records[0].phase == @execution.Settled
    }
    assert_true(h.runner.start(workflow_spec(run_id="board-run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.succeeded, 2)
    assert_eq(model.calls, 2)
    assert_eq(model.stopped, 2)
    // Fresh dedicated identity per execution; command IDs are correlation
    // data and never become execution or session identity.
    assert_eq(resolver.execution_ids.length(), 2)
    assert_false(resolver.execution_ids[0] == resolver.execution_ids[1])
    assert_false(resolver.session_ids[0] == resolver.session_ids[1])
    for command in ["board-run-1"] {
      for id in resolver.execution_ids {
        assert_false(id == command)
      }
      for id in resolver.session_ids {
        assert_false(id == command)
      }
    }
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[1].attempt_id, "attempt-beta-1")
    for binding in bindings {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.Completed))
    }
    // Each explicit input reached exactly its own scoped session.
    assert_true(model.inputs[0].contains("explicit workflow input 1"))
    assert_true(model.inputs[1].contains("explicit workflow input 2"))
    assert_eq(model.scopes[0].0, bindings[0].session_id)
    assert_eq(model.scopes[1].0, bindings[1].session_id)
    assert_eq(model.scopes[0].1, bindings[0].run.unwrap().run_id)
    assert_eq(model.scopes[1].1, bindings[1].run.unwrap().run_id)
    // The durable Board keeps the Ready tasks and records settled attempts
    // without ever seeing the ephemeral input or model output.
    let state = h.backend.state().unwrap()
    assert_eq(state.attempts.length(), 2)
    for task in state.tasks {
      assert_eq(task.stage, @domain.Ready)
    }
    for attempt in state.attempts {
      assert_true(attempt.review is None)
    }
    assert_eq(status.board_revision, Some(h.backend.state().unwrap().revision))
    for payload in workflow_event_payloads(h.backend) {
      assert_false(payload.contains("explicit workflow input"))
      assert_false(payload.contains("workflow settle complete"))
    }
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a real model failure stops the run under StopOnFailure" {
  @async.with_task_group(group => {
    let model = workflow_real_model(fail=true)
    let resolver = scripted_resolver(available=[
      "alpha/attempt-alpha-1", "beta/attempt-beta-1",
    ])
    let h = workflow_real_harness(
      group,
      tasks=["alpha", "beta"],
      model~,
      resolver~,
    )
    assert_true(h.runner.start(workflow_spec(run_id="board-run-2")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Failed))
    assert_eq(status.reason, Some(@workflow.ExecutionFailed(@execution.Failed)))
    assert_eq(model.calls, 1)
    assert_eq(model.stopped, 1)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[0].phase, @execution.Settled)
    assert_eq(bindings[0].outcome, Some(@execution.Failed))
    // beta was never admitted after the confirmed failure.
    assert_eq(resolver.execution_ids.length(), 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "cancel during a real held model run settles it as cancelled" {
  @async.with_task_group(group => {
    let model = workflow_real_model(hold=true)
    let resolver = scripted_resolver(available=["alpha/attempt-alpha-1"])
    let h = workflow_real_harness(group, tasks=["alpha"], model~, resolver~)
    assert_true(h.runner.start(workflow_spec(run_id="board-run-3")) is Ok(_))
    model.entered.get()
    h.runner.cancel()
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Stopped))
    assert_eq(model.calls, 1)
    assert_eq(model.stopped, 1)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].phase, @execution.Settled)
    assert_eq(bindings[0].outcome, Some(@execution.Cancelled))
    assert_eq(h.runner.status().succeeded, 0)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "pause and resume split two real model runs at a settled boundary" {
  @async.with_task_group(group => {
    let model = workflow_real_model(hold=true)
    let resolver = scripted_resolver(available=[
      "alpha/attempt-alpha-1", "beta/attempt-beta-1",
    ])
    let h = workflow_real_harness(
      group,
      tasks=["alpha", "beta"],
      model~,
      resolver~,
    )
    assert_true(h.runner.start(workflow_spec(run_id="board-run-4")) is Ok(_))
    model.entered.get()
    assert_true(h.runner.pause())
    model.release.put(())
    workflow_yield_until(what="paused after settle", check=() => {
      workflow_phase_eq(h.runner.status().phase, @workflow.Paused)
    })
    let paused = h.runner.status()
    assert_eq(paused.succeeded, 1)
    assert_eq(model.calls, 1)
    assert_true(h.runner.resume_workflow())
    model.entered.get()
    model.release.put(())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.succeeded, 2)
    assert_eq(model.calls, 2)
    assert_false(resolver.session_ids[0] == resolver.session_ids[1])
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
