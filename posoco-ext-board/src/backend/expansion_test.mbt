///|
/// Blackbox S4E1 backend suite: the trusted headless expansion route. The
/// wire command table gains nothing — `board.graph.expand` is rejected as
/// `invalid_command` — while the typed backend method commits the whole
/// atomic expansion durably and projects it onto the stream exactly once.

///|
fn expansion_backend() -> @backend.BoardBackend {
  @backend.BoardBackend::BoardBackend(now_ms=() => 5000L)
}

///|
fn expansion_candidate() -> @domain.GraphTask {
  @domain.GraphTask::from_record(
    id=@domain.BoardTaskId("child"),
    title="Expanded child",
    description="atomically expanded",
    priority=@domain.High,
    definition_of_done=["reviewed"],
    dependencies=[@domain.BoardTaskId("t1")],
    local_ref="plan/child",
  )
}

///|

///|
fn for_loop_found(
  tasks : Array[@domain.BoardTask],
  id : @domain.BoardTaskId,
) -> @domain.BoardTask? {
  for task in tasks {
    if task.id == id {
      return Some(task)
    }
  }
  None
}

///|
async fn backend_with_parent(
  group : @async.TaskGroup[Unit],
) -> @backend.BoardBackend {
  let backend = expansion_backend()
  backend.attach(group)
  let created = backend.handle_command(headless_create("c1", "t1", 0L))
  assert_true(created.accepted)
  backend
}

///|
async test "expand graph commits atomically and projects one authoritative event" {
  @async.with_task_group(group => {
    let backend = backend_with_parent(group)
    let events = backend
      .expand_graph(
        expansion=@domain.ExpansionId("exp-1"),
        candidates=[expansion_candidate()],
        parent=@domain.BoardTaskId("t1"),
        workflow="workflow-1",
        at_ms=Some(6000L),
        expected_revision=1L,
      )
      .unwrap()
    // Exactly one authoritative graph expansion event at revision + 1.
    assert_eq(events.length(), 1)
    guard events[0] is @domain.GraphExpanded(tasks~, mapping~, digest~, ..) else {
      fail("expected graph")
    }
    assert_eq(tasks.length(), 1)
    assert_eq(mapping[0].task_id, @domain.BoardTaskId("child"))
    assert_true(@domain.valid_expansion_digest(digest))
    // The committed board holds the Created candidate and the record.
    let state = backend.state().unwrap()
    assert_eq(state.revision, 2L)
    let child = for_loop_found(state.tasks, @domain.BoardTaskId("child"))
    guard child is Some(child) else {
      fail("the expanded candidate must be committed")
    }
    assert_true(child.stage is @domain.Created)
    assert_eq(child.dependencies, [@domain.BoardTaskId("t1")])
    let history = backend.expansion_history().unwrap()
    assert_eq(history.length(), 1)
    assert_eq(history[0].expansion_id, @domain.ExpansionId("exp-1"))
    assert_eq(history[0].mapping[0].task_id, @domain.BoardTaskId("child"))
    assert_eq(history[0].parent_task_id, @domain.BoardTaskId("t1"))
    assert_eq(history[0].mapping[0].local_ref, "plan/child")
    assert_eq(history[0].workflow_id, "workflow-1")
    assert_eq(history[0].created_at_ms, 6000L)
    // The stream observed the expansion exactly once.
    let stream = backend.event_history()
    assert_eq(stream.length(), 2)
    assert_eq(stream[1].kind, "board.graph.expanded")
    assert_eq(stream[1].board_revision, 2L)
    // The composite bootstrap contains the expanded task.
    let frame = backend.bootstrap_snapshot().unwrap()
    assert_eq(frame.board_revision, 2L)
    assert_eq(frame.last_seq, 2L)
    backend.shutdown()
  })
}

///|
async test "reuse of a committed expansion id is rejected as duplicate" {
  @async.with_task_group(group => {
    let backend = backend_with_parent(group)
    let first = backend.expand_graph(
      expansion=@domain.ExpansionId("exp-1"),
      candidates=[expansion_candidate()],
      parent=@domain.BoardTaskId("t1"),
      workflow="workflow-1",
      expected_revision=1L,
    )
    assert_true(first is Ok(_))
    // Same content: rejected, never an idempotent replay.
    assert_eq(
      backend.expand_graph(
        expansion=@domain.ExpansionId("exp-1"),
        candidates=[expansion_candidate()],
        parent=@domain.BoardTaskId("t1"),
        workflow="workflow-1",
        expected_revision=2L,
      ),
      Err(
        @coordinator.Rejected(
          @domain.DuplicateExpansion(expansion=@domain.ExpansionId("exp-1")),
        ),
      ),
    )
    // Conflicting content under the same identity: rejected too.
    let conflicting = @domain.GraphTask::from_record(
      id=@domain.BoardTaskId("other"),
      title="Different child",
      description="",
      priority=@domain.Low,
      definition_of_done=[],
      dependencies=[],
      local_ref="plan/other",
    )
    assert_true(
      backend.expand_graph(
        expansion=@domain.ExpansionId("exp-1"),
        candidates=[conflicting],
        parent=@domain.BoardTaskId("t1"),
        workflow="workflow-1",
        expected_revision=2L,
      )
      is Err(@coordinator.Rejected(@domain.DuplicateExpansion(_))),
    )
    // Nothing extra was committed or published.
    assert_eq(backend.state().unwrap().revision, 2L)
    assert_eq(backend.expansion_history().unwrap().length(), 1)
    assert_eq(backend.current_seq(), 2L)
    backend.shutdown()
  })
}

///|
async test "expand graph answers a stale revision with the live one" {
  @async.with_task_group(group => {
    let backend = backend_with_parent(group)
    assert_eq(
      backend.expand_graph(
        expansion=@domain.ExpansionId("exp-stale"),
        candidates=[expansion_candidate()],
        parent=@domain.BoardTaskId("t1"),
        workflow="workflow-1",
        expected_revision=0L,
      ),
      Err(
        @coordinator.Rejected(@domain.RevisionConflict(expected=0L, actual=1L)),
      ),
    )
    assert_eq(backend.state().unwrap().revision, 1L)
    backend.shutdown()
  })
}

///|
async test "the wire command table gains no privileged expansion route" {
  @async.with_task_group(group => {
    let backend = backend_with_parent(group)
    // An expansion-shaped frame is structurally rejected before any state
    // is read: the browser allowlist stays exactly the fixed eight names.
    for
      name in [
        "board.graph.expand", "board.graph.expansion", "board.expansion.create",
      ] {
      let result = backend.handle_command({
        command_id: "c-graph",
        name,
        expected_revision: 1L,
        args: {
          "expansion_id": "exp-1",
          "candidate": Json::object({ "id": "child", "local_ref": "plan/child" }),
          "parent": "t1",
        },
      })
      assert_eq(result.command_id, "c-graph")
      assert_false(result.accepted)
      assert_eq(result.error, Some("invalid_command"))
    }
    assert_eq(backend.state().unwrap().revision, 1L)
    assert_eq(backend.current_seq(), 1L)
    backend.shutdown()
  })
}

///|
async test "expansion history answers initializing before restore settles" {
  let backend = expansion_backend()
  // Never attached: the coordinator has no durable board yet.
  assert_true(backend.expansion_history() is Err(@coordinator.NotAttached))
  assert_true(
    backend.expand_graph(
      expansion=@domain.ExpansionId("e"),
      candidates=[expansion_candidate()],
      parent=@domain.BoardTaskId("t1"),
      workflow="workflow-1",
      expected_revision=0L,
    )
    is Err(@coordinator.NotAttached),
  )
}
