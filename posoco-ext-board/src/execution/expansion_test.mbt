///|
async test "atomic expansion preserves active slot identities and subsequent settlements" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 2)
    let store = journal()
    let adapters : Array[ControlledAdapter] = []
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store~,
      adapter_factory=_ => {
        let adapter = controlled(block=true)
        adapters.push(adapter)
        adapter
      },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let first = owner
      .execute(slot_request(task=1, attempt="attempt-1", execution=1))
      .unwrap()
    let second = owner
      .execute(slot_request(task=2, attempt="attempt-2", execution=2))
      .unwrap()
    adapters[0].entered.get()
    adapters[1].entered.get()
    let running = store.records.copy()
    let before = backend.state().unwrap()
    let candidates = [
      @domain.GraphTask::from_record(
        id=@domain.BoardTaskId("generated-a"),
        local_ref="a",
        title="A",
        description="",
        priority=@domain.Normal,
        definition_of_done=[],
        dependencies=[],
      ),
      @domain.GraphTask::from_record(
        id=@domain.BoardTaskId("generated-b"),
        local_ref="b",
        title="B",
        description="",
        priority=@domain.Normal,
        definition_of_done=[],
        dependencies=[@domain.BoardTaskId("generated-a")],
      ),
    ]
    let event = backend
      .expand_graph(
        expansion=@domain.ExpansionId("active-expansion"),
        candidates~,
        parent=@domain.BoardTaskId("task-1"),
        workflow="explicit-host-workflow",
        expected_revision=before.revision,
      )
      .unwrap()
    assert_eq(event.length(), 1)
    assert_eq(store.records, running)
    assert_eq(owner.status().active_bindings.length(), 2)
    let expanded = backend.state().unwrap()
    assert_eq(expanded.revision, before.revision + 1L)
    assert_eq(expanded.attempts, before.attempts)
    for index in 0..<before.tasks.length() {
      assert_eq(expanded.tasks[index], before.tasks[index])
    }
    for
      task in expanded.tasks.filter(task => {
        task.id.value.has_prefix("generated-")
      }) {
      assert_eq(task.stage, @domain.Created)
      assert_false(expanded.attempts.any(attempt => attempt.task_id == task.id))
    }
    adapters[0].release.put(())
    let settled_first = first.wait()
    assert_eq(settled_first.phase, @execution.Settled)
    assert_eq(settled_first.execution_id, "exec-1")
    assert_eq(store.records[1], running[1])
    assert_eq(owner.status().active_bindings.length(), 1)
    // A settlement is an authoritative concurrent edit, not permission to
    // silently reuse an earlier expansion approval/revision.
    assert_true(
      backend.expand_graph(
        expansion=@domain.ExpansionId("stale-expansion"),
        candidates~,
        parent=@domain.BoardTaskId("task-1"),
        workflow="explicit-host-workflow",
        expected_revision=expanded.revision,
      )
      is Err(@coordinator.Rejected(@domain.RevisionConflict(..))),
    )
    adapters[1].release.put(())
    let settled_second = second.wait()
    assert_eq(settled_second.phase, @execution.Settled)
    assert_eq(settled_second.execution_id, "exec-2")
    let final_state = backend.state().unwrap()
    assert_eq(final_state.tasks, expanded.tasks)
    assert_eq(final_state.expansions, expanded.expansions)
    assert_eq(final_state.attempts.length(), 2)
    for attempt in final_state.attempts {
      assert_eq(attempt.status, @domain.Succeeded)
    }
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}
