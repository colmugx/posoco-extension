///|
async test "one composed extension owns actual Agent planning graph approval scope and durable dependent execution" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group, max_executions=3)
    defer ignore(h.board.shutdown())
    let committed = proposed(h)
    let run = committed.run.checked()
    let expansion = committed.snapshot.expansions[0]
    let a = expansion.mapping[0].task_id.value
    let b = expansion.mapping[1].task_id.value
    assert_eq(run.scope.length(), 1)
    assert_eq(run.runner.remaining_executions, 2)
    assert_true(
      committed.snapshot.tasks
      .filter(t => t.id.value == a || t.id.value == b)
      .all(t => t.stage == @domain.Created),
    )
    assert_false(
      committed.snapshot.attempts.any(attempt => {
        attempt.task_id.value == a || attempt.task_id.value == b
      }),
    )
    assert_true(
      h.board.prepare(task_id=a, input="trusted execution input") is Err(_),
    )
    let authorized = h.board
      .scope_decision(expansion_id=expansion.expansion_id.value, grant=true)
      .checked()
    assert_eq(authorized.run.checked().scope.length(), 3)
    assert_eq(authorized.run.checked().runner.remaining_executions, 2)
    ignore(
      h.board
      .prepare(task_id=a, input="private trusted A execution input")
      .checked(),
    )
    ignore(
      h.board
      .prepare(task_id=b, input="private trusted B execution input")
      .checked(),
    )
    ignore(h.board.run_wave().checked())
    let first = h.board.wait_boundary().checked()
    assert_true(
      first.snapshot.attempts.any(x => {
        x.task_id.value == a && x.status == @domain.Succeeded
      }),
    )
    assert_true(
      first.snapshot.attempts.any(x => {
        x.task_id.value == b && x.status == @domain.Queued
      }),
    )
    assert_eq(
      first.snapshot.tasks.filter(t => t.id.value == a)[0].stage,
      @domain.Ready,
    )
    assert_true(
      first.run.checked().blocked.any(x => {
        x.task_id == b &&
        x.reasons.contains(@orchestration.DependencyNotDone(a))
      }),
    )
    assert_false(first.snapshot.attempts.any(x => x.kind == @domain.Review))
    for
      stage in (
        [@domain.Running, @domain.Review, @domain.Done] :
        Array[@domain.BoardStage]) {
      ignore(
        h.board
        .move_task(
          task_id=a,
          stage~,
          evidence="operator independently verified evidence",
        )
        .checked(),
      )
    }
    ignore(h.board.run_wave().checked())
    let done = h.board.wait_boundary().checked()
    assert_eq(done.run.checked().runner.remaining_executions, 0)
    assert_eq(done.executions.length(), 3)
    assert_true(
      done.executions.all(e => {
        e.phase == @execution.Settled && e.outcome == Some(@execution.Completed)
      }),
    )
    assert_eq(
      Set::from_array(done.executions.map(e => e.session_id)).length(),
      3,
    )
    let journal = @execution.encode_execution_journal(done.executions).checked()
    for
      private_text in [
        "private trusted", "trusted user coding requirements", "private actual Agent execution result",
      ] {
      assert_false(journal.contains(private_text))
    }
    assert_true(h.ui.prompts.any(p => p.has_prefix("GRAPH APPROVAL")))
    assert_true(h.ui.prompts.any(p => p.has_prefix("EXECUTION SCOPE APPROVAL")))
    h.parent.shutdown()
    let reacquired = @journal.FileBoardExecutionStore(directory~)
    assert_true(reacquired.load() is Ok(_))
    reacquired.close()
  })
}

///|
async test "default workflow denial causes no storage or model effects" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group, enabled=false)
    defer ignore(h.board.shutdown())
    assert_eq(h.board.start(title="Disabled"), Err(@service.Disabled))
    assert_eq(h.board.view().checked().snapshot.tasks.length(), 0)
    assert_true(h.state.contexts.is_empty())
    assert_true(h.ui.prompts.is_empty())
  })
}

///|
async test "operator start denial and reentrant cancellation cannot authorize mutations" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group)
    defer ignore(h.board.shutdown())
    h.ui.grant = false
    assert_eq(h.board.start(title="Denied"), Err(@service.ApprovalDenied))
    assert_eq(h.board.view().checked().snapshot.tasks.length(), 0)
    h.ui.grant = true
    h.ui.before_answer = Some(() => h.board.cancel())
    assert_eq(
      h.board.start(title="Cancelled during approval"),
      Err(@service.Closed),
    )
    assert_eq(h.board.view().checked().snapshot.tasks.length(), 0)
  })
}

///|
async test "invalid structured Agent output cannot commit a graph or claim Agent failure" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group)
    defer ignore(h.board.shutdown())
    let initial = h.board.start(title="Invalid output").checked()
    h.state.invalid = true
    let result = h.board.propose(
      parent=initial.run.checked().scope[0],
      requirements="private user requirements",
    )
    assert_eq(result, Err(@service.InvalidProposal))
    let current = h.board.view().checked()
    assert_eq(current.snapshot.tasks.length(), 1)
    assert_true(current.snapshot.expansions.is_empty())
    assert_eq(current.executions[0].outcome, Some(@execution.Completed))
    assert_false(
      current.to_json().stringify().contains("invalid private raw model output"),
    )
  })
}

///|
async test "graph denial leaves proposal nonauthoritative and scope denial retains committed graph" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group)
    defer ignore(h.board.shutdown())
    let first = h.board.start(title="Denied DAG").checked()
    ignore(
      h.board
      .propose(
        parent=first.run.checked().scope[0],
        requirements="planning input",
      )
      .checked(),
    )
    assert_true(
      h.board.graph_decision(grant=false) is Err(@service.ApprovalDenied),
    )
    assert_true(h.board.view().checked().snapshot.expansions.is_empty())
  })
  let other = @fixtures.temporary_directory()
  defer @fixtures.cleanup(other)
  @async.with_task_group(group => {
    let h = harness(other, group)
    defer ignore(h.board.shutdown())
    let committed = proposed(h)
    assert_true(
      h.board.scope_decision(
        expansion_id=committed.snapshot.expansions[0].expansion_id.value,
        grant=false,
      )
      is Err(@service.ApprovalDenied),
    )
    let current = h.board.view().checked()
    assert_eq(current.snapshot.expansions.length(), 1)
    assert_eq(current.run.checked().scope.length(), 1)
    assert_eq(current.snapshot.tasks.length(), 3)
  })
}

///|
async test "extension lock prevents a competing client and cannot be released by that client" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let first = harness(directory, group)
    defer ignore(first.board.shutdown())
    ignore(first.board.start(title="Owner").checked())
    let other = harness(directory, group)
    assert_true(
      other.board.start(title="Competing writer")
      is Err(@service.StoreUnavailable),
    )
    assert_true(other.board.shutdown())
    let probe = @journal.FileBoardExecutionStore(directory~)
    assert_true(probe.load() is Err(_))
    probe.close()
    assert_eq(first.board.view().checked().snapshot.tasks.length(), 1)
  })
}

///|
async test "restart exposes durable graph but never restores scope or execution inputs" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group)
    let graph = proposed(h)
    ignore(
      h.board
      .scope_decision(
        expansion_id=graph.snapshot.expansions[0].expansion_id.value,
        grant=true,
      )
      .checked(),
    )
    assert_true(h.board.shutdown())
  })
  @async.with_task_group(group => {
    let reopened = harness(directory, group)
    defer ignore(reopened.board.shutdown())
    let view = reopened.board.view().checked()
    assert_true(view.run is None)
    assert_eq(view.snapshot.expansions.length(), 1)
    assert_eq(view.snapshot.tasks.length(), 3)
    assert_true(reopened.state.contexts.is_empty())
    assert_true(reopened.board.run_wave() is Err(@service.NotStarted))
  })
}

///|
async test "planning cancellation joins exact actual Agent and permits only explicit resume" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group, continue_on_confirmed_failure=true)
    defer ignore(h.board.shutdown())
    let started = h.board.start(title="Pause planning").checked()
    h.state.delay = 1000
    let work = group.spawn(() => {
      assert_true(
        h.board.propose(
          parent=started.run.checked().scope[0],
          requirements="planning",
        )
        is Err(_),
      )
    })
    while h.state.active == 0 {
      @async.sleep(1)
    }
    assert_true(h.board.pause())
    work.wait()
    assert_eq(h.state.active, 0)
    let status = h.board.view().checked()
    assert_true(status.executions.all(e => e.phase == @execution.Settled))
    assert_true(status.snapshot.expansions.is_empty())
    ignore(h.board.resume_workflow().checked())
  })
}

///|
async test "two actual execution Agents use independent identities and bounded slots" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group)
    defer ignore(h.board.shutdown())
    h.state.chain = false
    let graph = proposed(h)
    let expansion = graph.snapshot.expansions[0]
    ignore(
      h.board
      .scope_decision(expansion_id=expansion.expansion_id.value, grant=true)
      .checked(),
    )
    for mapping in expansion.mapping {
      ignore(
        h.board
        .prepare(
          task_id=mapping.task_id.value,
          input="trusted per-task execution input",
        )
        .checked(),
      )
    }
    h.state.delay = -1
    ignore(h.board.run_wave().checked())
    let done = h.board.wait_boundary().checked()
    assert_eq(h.state.peak, 2)
    assert_eq(done.executions.length(), 3)
    assert_true(done.executions.all(b => b.phase == @execution.Settled))
    assert_eq(
      h.state.contexts
      .filter(c => c.purpose == @service.WorkflowAgentPurpose::Execution)
      .length(),
      2,
    )
  })
}

///|
async test "unresolved journal is read-only evidence not fresh execution authority" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  let records : Array[@execution.BoardExecutionBinding] = [
    {
      task_id: "old-task",
      attempt_id: "old-attempt",
      execution_id: "old-execution",
      session_id: "old-session",
      run: None,
      phase: @execution.Reserved,
      outcome: None,
    },
  ]
  @fixtures.put(
    directory + "/executions.json",
    @execution.encode_execution_journal(records).checked(),
  )
  @async.with_task_group(group => {
    let h = harness(directory, group)
    assert_true(h.board.view().checked().unresolved)
    assert_true(
      h.board.start(title="Must not replay")
      is Err(@service.UnresolvedExecution),
    )
    assert_false(h.board.shutdown())
    assert_true(h.state.contexts.is_empty())
    assert_eq(
      @journal.FileBoardExecutionStore::inspect(directory~).checked(),
      records,
    )
  })
}
