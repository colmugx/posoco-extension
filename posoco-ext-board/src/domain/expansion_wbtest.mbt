///|
fn expansion_seed() -> BoardState raise {
  accept(BoardState::BoardState(), create_cmd("parent", 0L)).next_state
}

///|
fn expansion_candidates() -> Array[GraphTask] {
  [
    GraphTask::from_record(
      id=tid("a"),
      title="A",
      description="é:🙂",
      priority=Normal,
      definition_of_done=["ok"],
      dependencies=[tid("b")],
      local_ref="a",
    ),
    GraphTask::from_record(
      id=tid("b"),
      title="B",
      description="",
      priority=High,
      definition_of_done=[],
      dependencies=[tid("parent")],
      local_ref="b",
    ),
  ]
}

///|
fn expansion_accept(state : BoardState) -> BoardProposal raise {
  accept(
    state,
    ExpandGraph(
      expansion=ExpansionId("proposal"),
      candidates=expansion_candidates(),
      parent=tid("parent"),
      workflow="workflow",
      at_ms=10L,
      expected_revision=state.revision(),
    ),
  )
}

///|
test "whole graph command event snapshot and history arrays are detached" {
  let state = expansion_seed()
  let candidates = expansion_candidates()
  let command = ExpandGraph(
    expansion=ExpansionId("proposal"),
    candidates~,
    parent=tid("parent"),
    workflow="workflow",
    at_ms=10L,
    expected_revision=1L,
  ).copy_detached()
  candidates[0].dependencies[0] = tid("ghost")
  candidates.clear()
  let proposal = accept(state, command)
  guard proposal.events[0] is GraphExpanded(tasks~, mapping~, ..) else {
    fail("event missing")
  }
  tasks[0].dependencies.clear()
  mapping.clear()
  assert_eq(proposal.next_state.task(tid("a")).unwrap().dependencies, [tid("b")])
  let record = proposal.next_state.expansions()[0]
  record.mapping.clear()
  let snapshot = proposal.next_state.snapshot()
  snapshot.expansions[0].mapping.clear()
  assert_eq(proposal.next_state.expansions()[0].mapping.length(), 2)
}

///|
test "restore fails closed for malformed identity mappings digest and duplicates" {
  let snapshot = expansion_accept(expansion_seed()).next_state.snapshot()
  let record = snapshot.expansions[0]
  for
    damaged in [
      { ..record, expansion_id: ExpansionId(""), },
      { ..record, workflow_id: " ", },
      { ..record, content_digest: "fnv1a64:0123456789abcdef", },
      { ..record, content_digest: "sha256:" + "g".repeat(64), },
      { ..record, created_at_ms: -1L, },
      { ..record, parent_task_id: tid("ghost"), },
      { ..record, mapping: [], },
      { ..record, mapping: [{ local_ref: "", task_id: tid("a"), }], },
      { ..record, mapping: [{ local_ref: "a", task_id: tid("ghost"), }], },
      { ..record, mapping: [{ local_ref: "a", task_id: tid("parent"), }], },
      {
        ..record,
        mapping: [
          { local_ref: "a", task_id: tid("a"), },
          { local_ref: "a", task_id: tid("b"), },
        ],
      },
      {
        ..record,
        mapping: [
          { local_ref: "a", task_id: tid("a"), },
          { local_ref: "b", task_id: tid("a"), },
        ],
      },
    ] {
    assert_true(
      BoardState::from_snapshot({ ..snapshot, expansions: [damaged], })
      is Err(_),
    )
  }
  assert_true(
    BoardState::from_snapshot({ ..snapshot, expansions: [record, record], })
    is Err(DuplicateExpansion(..)),
  )
  assert_true(
    BoardState::from_snapshot({
      ..snapshot,
      expansions: [record, { ..record, expansion_id: ExpansionId("other"), }],
    })
    is Err(_),
  )
}

///|
test "SHA256 exact framed UTF8 content golden vector" {
  let digest = expansion_content_digest(
    expansion=ExpansionId("proposal"),
    candidates=expansion_candidates(),
    parent=tid("parent"),
    workflow="workflow",
  )
  assert_eq(
    digest, "sha256:529b53942630cd9f09b631481226312f055baa8d2e533572cf511d73a12378b8",
  )
}
