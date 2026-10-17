///|
fn expansion_event() -> @protocol.BoardWireEvent {
  let parent = @domain.BoardTask::from_record(
    id=@domain.BoardTaskId("t1"),
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
    revision: 0L,
    tasks: [parent],
    attempts: [],
    expansions: [],
  }).unwrap()
  let candidates = [
    @domain.GraphTask::from_record(
      id=@domain.BoardTaskId("a"),
      title="A",
      description="",
      priority=@domain.High,
      definition_of_done=[],
      dependencies=[@domain.BoardTaskId("b")],
      local_ref="first",
    ),
    @domain.GraphTask::from_record(
      id=@domain.BoardTaskId("b"),
      title="B",
      description="",
      priority=@domain.Normal,
      definition_of_done=[],
      dependencies=[@domain.BoardTaskId("t1")],
      local_ref="second",
    ),
  ]
  let proposal = @domain.BoardDomain::propose(
    state,
    @domain.ExpandGraph(
      expansion=@domain.ExpansionId("proposal"),
      candidates~,
      parent=@domain.BoardTaskId("t1"),
      workflow="workflow",
      at_ms=3000L,
      expected_revision=0L,
    ),
  ).unwrap()
  let wire = @protocol.project_event(
    proposal.next_state.snapshot(),
    proposal.events[0],
  )
  { ..wire, seq: 1L, }
}

///|
fn expansion_baseline() -> @client.BoardReplica raise {
  let replica = @client.BoardReplica::empty()
  assert_eq_eq(
    replica.apply_snapshot(
      snapshot_frame(revision=0L, last_seq=0L, tasks=[wire_task()]),
    ),
    @client.Applied,
  )
  replica
}

///|
test "whole graph forward ref applies atomically then replay is a duplicate" {
  let replica = expansion_baseline()
  let event = expansion_event()
  assert_eq_eq(replica.apply_event(event), @client.Applied)
  assert_eq(replica.tasks().length(), 3)
  assert_eq(replica.tasks()[1].id, "a")
  assert_eq(replica.tasks()[1].dependencies, ["b"])
  assert_eq(replica.tasks()[2].id, "b")
  assert_eq(replica.revision(), 1L)
  assert_eq(replica.last_seq(), 1L)
  assert_eq_eq(replica.apply_event(event), @client.Duplicate)
  // Duplicate payload is ignored before decode, never partially reapplied.
  assert_eq_eq(
    replica.apply_event({ ..event, payload: Json::null(), }),
    @client.Duplicate,
  )
  assert_eq(replica.tasks().length(), 3)
}

///|
test "malformed late entity mapping digest or lineage never partially applies" {
  let event = expansion_event()
  let base = match event.payload {
    Json::Object(f) => f
    _ => abort("object")
  }
  let valid_tasks = match base["tasks"] {
    Json::Array(tasks) => tasks
    _ => abort("array")
  }
  let invalid : Array[Json] = []
  for
    pair in [
      ("tasks", Json::array([valid_tasks[0], Json::null()])),
      ("mapping", Json::array([{ "local_ref": "first", "task_id": "a" }])),
      ("workflow_id", Json::null()),
      ("workflow_id", Json::string("different")),
      ("parent_task_id", Json::string("ghost")),
      ("content_digest", Json::string("fnv1a64:0123456789abcdef")),
    ] {
    let f = base.copy()
    f[pair.0] = pair.1
    invalid.push(Json::object(f))
  }
  for payload in invalid {
    let replica = expansion_baseline()
    assert_true(
      replica.apply_event({ ..event, payload, }) is @client.NeedsSnapshot(_),
    )
    assert_false(replica.has_snapshot())
    assert_eq(replica.tasks().length(), 0)
    assert_eq(replica.last_seq(), 0L)
    assert_eq(replica.revision(), 0L)
  }
}

///|
test "whole graph replica validates full DAG even with a correctly bound digest" {
  // The checksum is not authority: a malicious but self-consistent invalid DAG
  // still fails the shared domain validator before any projection is installed.
  let event = expansion_event()
  let base = match event.payload {
    Json::Object(f) => f
    _ => abort("object")
  }
  let tasks = match base["tasks"] {
    Json::Array(tasks) => tasks
    _ => abort("array")
  }
  let second = match tasks[1] {
    Json::Object(f) => f.copy()
    _ => abort("object")
  }
  second["dependencies"] = Json::array([Json::string("a")])
  base["tasks"] = Json::array([tasks[0], Json::object(second)])
  let candidates = [
    @domain.GraphTask::from_record(
      id=@domain.BoardTaskId("a"),
      title="A",
      description="",
      priority=@domain.High,
      definition_of_done=[],
      dependencies=[@domain.BoardTaskId("b")],
      local_ref="first",
    ),
    @domain.GraphTask::from_record(
      id=@domain.BoardTaskId("b"),
      title="B",
      description="",
      priority=@domain.Normal,
      definition_of_done=[],
      dependencies=[@domain.BoardTaskId("a")],
      local_ref="second",
    ),
  ]
  base["content_digest"] = Json::string(
    @domain.expansion_content_digest(
      expansion=@domain.ExpansionId("proposal"),
      candidates~,
      parent=@domain.BoardTaskId("t1"),
      workflow="workflow",
    ),
  )
  let replica = expansion_baseline()
  assert_eq_eq(
    replica.apply_event({ ..event, payload: Json::object(base), }),
    @client.NeedsSnapshot("invalid expansion graph"),
  )
  assert_eq(replica.tasks().length(), 0)
}

///|
test "expansion requires next revision baseline and contiguous cursor" {
  let event = expansion_event()
  assert_eq_eq(
    expansion_baseline().apply_event({ ..event, seq: 2L, }),
    @client.NeedsSnapshot("event sequence gap"),
  )
  assert_eq_eq(
    expansion_baseline().apply_event({ ..event, board_revision: 0L, }),
    @client.NeedsSnapshot("expansion revision discontinuity"),
  )
  assert_eq_eq(
    expansion_baseline().apply_event({ ..event, board_revision: 7L, }),
    @client.NeedsSnapshot("board revision discontinuity"),
  )
  assert_eq_eq(
    @client.BoardReplica::empty().apply_event(event),
    @client.NeedsSnapshot("board event requires snapshot"),
  )
}
