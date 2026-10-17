///|
fn graph_projection_proposal() -> @domain.BoardProposal {
  let parent = @domain.BoardTask::from_record(
    id=projection_id(),
    title="parent",
    description="",
    stage=@domain.Created,
    priority=@domain.Normal,
    definition_of_done=[],
    dependencies=[],
    created_at_ms=1L,
    updated_at_ms=1L,
    ready_since_ms=None,
  )
  let state = @domain.BoardState::from_snapshot({
    revision: 1L,
    tasks: [parent],
    attempts: [],
    expansions: [],
  }).unwrap()
  let candidates = [
    @domain.GraphTask::from_record(
      id=projection_id(value="a"),
      title="A",
      description="",
      priority=@domain.High,
      definition_of_done=[],
      dependencies=[projection_id(value="b")],
      local_ref="first",
    ),
    @domain.GraphTask::from_record(
      id=projection_id(value="b"),
      title="B",
      description="",
      priority=@domain.Normal,
      definition_of_done=[],
      dependencies=[projection_id()],
      local_ref="second",
    ),
  ]
  @domain.BoardDomain::propose(
    state,
    @domain.ExpandGraph(
      expansion=@domain.ExpansionId("proposal"),
      candidates~,
      parent=projection_id(),
      workflow="workflow",
      at_ms=50L,
      expected_revision=1L,
    ),
  ).unwrap()
}

///|
test "graph projection carries complete ordered tasks and mapping in one wire event" {
  let proposal = graph_projection_proposal()
  let wire = project_event(proposal.next_state.snapshot(), proposal.events[0])
  assert_eq(wire.seq, 0L)
  assert_eq(wire.scope, None)
  assert_eq(wire.board_revision, 2L)
  assert_eq(wire.kind, "board.graph.expanded")
  assert_eq(text_field(wire.payload, "workflow_id"), "workflow")
  assert_eq(text_field(wire.payload, "parent_task_id"), "t1")
  assert_eq(text_field(wire.payload, "expansion_id"), "proposal")
  guard object_field(wire.payload, "tasks") is Json::Array(tasks) else {
    fail("tasks array")
  }
  assert_eq(tasks.length(), 2)
  assert_eq(text_field(tasks[0], "id"), "a")
  assert_eq(text_field(tasks[1], "id"), "b")
  assert_eq(
    object_field(tasks[0], "dependencies"),
    Json::array([Json::string("b")]),
  )
  assert_eq(
    object_field(wire.payload, "mapping"),
    Json::array([
      { "local_ref": "first", "task_id": "a" },
      { "local_ref": "second", "task_id": "b" },
    ]),
  )
  assert_eq(keys_of(wire.payload).length(), 7)
}
