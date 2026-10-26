///|
/// Black-box S4E1 core suite: the atomic additive graph expansion through
/// the public domain API — propose, preview, identity conflicts, DAG
/// validation reuse, immutability of existing work, and snapshot restore.

///|
fn xtid(s : String) -> @domain.BoardTaskId {
  @domain.BoardTaskId::BoardTaskId(s)
}

///|
fn xeid(s : String) -> @domain.ExpansionId {
  @domain.ExpansionId::ExpansionId(s)
}

///|
fn xcandidate(
  id~ : String = "child",
  local_ref~ : String = "plan/child",
  deps~ : Array[String] = [],
  title~ : String = "Expanded child",
) -> @domain.GraphTask {
  @domain.GraphTask::from_record(
    id=xtid(id),
    title~,
    description="atomically expanded",
    priority=@domain.High,
    definition_of_done=["reviewed"],
    dependencies=deps.map(xtid),
    local_ref~,
  )
}

///|
/// Parent in Created plus one unrelated Refining task, at revision 3.
fn xseed() -> @domain.BoardState {
  let empty = @domain.BoardState::BoardState()
  let first = @domain.BoardDomain::propose(
    empty,
    @domain.CreateTask(
      id=xtid("parent"),
      title="Expandable parent",
      description="",
      priority=@domain.Normal,
      definition_of_done=[],
      dependencies=[],
      user_story="",
      implementation_suggestions="",
      at_ms=1000L,
      expected_revision=0L,
    ),
  ).unwrap()
  let second = @domain.BoardDomain::propose(
    first.next_state,
    @domain.CreateTask(
      id=xtid("other"),
      title="Unrelated sibling",
      description="",
      priority=@domain.Low,
      definition_of_done=[],
      dependencies=[],
      user_story="",
      implementation_suggestions="",
      at_ms=2000L,
      expected_revision=1L,
    ),
  ).unwrap()
  @domain.BoardDomain::propose(
    second.next_state,
    @domain.MoveTask(
      id=xtid("other"),
      to=@domain.Refining,
      at_ms=3000L,
      expected_revision=2L,
    ),
  ).unwrap().next_state
}

///|
fn x_rejection(
  state : @domain.BoardState,
  command : @domain.BoardCommand,
) -> @domain.BoardError raise {
  match @domain.BoardDomain::propose(state, command) {
    Ok(_) => fail("expected the expansion to be rejected")
    Err(error) => error
  }
}

///|
fn xexpand(
  candidates~ : Array[@domain.GraphTask] = [
    xcandidate(id="child", deps=["later"]),
    xcandidate(id="later", local_ref="plan/later", deps=["parent"]),
  ],
  expansion~ : String = "exp-1",
  workflow~ : String = "wf-1",
  parent~ : String = "parent",
  rev~ : Int64 = 3L,
) -> @domain.BoardCommand {
  @domain.ExpandGraph(
    expansion=xeid(expansion),
    candidates~,
    parent=xtid(parent),
    workflow~,
    at_ms=5000L,
    expected_revision=rev,
  )
}

///|
test "whole proposal supports forward references with one revision event and identity" {
  let state = xseed()
  let before = state.snapshot()
  let command = xexpand()
  let proposal = @domain.BoardDomain::propose(state, command).unwrap()
  assert_eq(state.snapshot(), before)
  assert_eq(proposal.next_state.revision(), 4L)
  assert_eq(proposal.next_state.tasks().length(), 4)
  assert_eq(proposal.next_state.attempts(), [])
  assert_eq(
    proposal.next_state.task(xtid("parent")),
    state.task(xtid("parent")),
  )
  assert_eq(proposal.next_state.task(xtid("other")), state.task(xtid("other")))
  assert_eq(proposal.events.length(), 1)
  guard proposal.events[0]
    is @domain.GraphExpanded(tasks~, mapping~, digest~, workflow~, ..) else {
    fail("expected whole graph event")
  }
  assert_eq(tasks.length(), 2)
  assert_eq(tasks[0].dependencies, [xtid("later")])
  for task in tasks {
    assert_eq(task.stage, @domain.Created)
    assert_eq(task.created_at_ms, 5000L)
    assert_eq(task.updated_at_ms, 5000L)
    assert_eq(task.ready_since_ms, None)
  }
  assert_eq(mapping, [
    { local_ref: "plan/child", task_id: xtid("child"), },
    { local_ref: "plan/later", task_id: xtid("later"), },
  ])
  assert_eq(workflow, "wf-1")
  assert_true(@domain.valid_expansion_digest(digest))
  let history = proposal.next_state.expansions()
  assert_eq(history.length(), 1)
  assert_eq(history[0].mapping, mapping)
  assert_eq(history[0].content_digest, digest)
  assert_eq(
    @domain.BoardState::from_snapshot(proposal.next_state.snapshot())
    .unwrap()
    .snapshot(),
    proposal.next_state.snapshot(),
  )
}

///|
test "whole proposal DAG rejection is atomic including late invalid nodes and cycles" {
  let state = xseed()
  let before = state.snapshot()
  let bad : Array[Array[@domain.GraphTask]] = [
    [],
    [xcandidate(), xcandidate(id="later", local_ref="later", deps=["ghost"])],
    [
      xcandidate(deps=["later"]),
      xcandidate(id="later", local_ref="later", deps=["child"]),
    ],
    [xcandidate(deps=["child"])],
    [xcandidate(deps=["parent", "parent"])],
    [xcandidate(), xcandidate(id="child", local_ref="later")],
    [xcandidate(), xcandidate(id="later")],
    [xcandidate(), xcandidate(id="other", local_ref="later")],
    [xcandidate(local_ref=" ")],
    [xcandidate(title="")],
    [xcandidate(id="")],
  ]
  for candidates in bad {
    assert_true(
      @domain.BoardDomain::propose(state, xexpand(candidates~)) is Err(_),
    )
    assert_eq(state.snapshot(), before)
  }
  assert_eq(
    x_rejection(state, xexpand(parent="ghost")),
    @domain.TaskMissing(task=xtid("ghost")),
  )
  assert_eq(
    x_rejection(state, xexpand(rev=2L)),
    @domain.RevisionConflict(expected=2L, actual=3L),
  )
  assert_true(
    @domain.BoardDomain::propose(state, xexpand(workflow=" \n")) is Err(_),
  )
  assert_true(
    @domain.BoardDomain::propose(state, xexpand(expansion=" ")) is Err(_),
  )
}

///|
test "preview is exact and stable proposal ID cannot be replayed with fresh allocation" {
  let state = xseed()
  let candidates = [
    xcandidate(deps=["later"]),
    xcandidate(id="later", local_ref="plan/later"),
  ]
  let preview = @domain.BoardDomain::preview_expand_graph(
    state.snapshot(),
    expansion=xeid("exp-1"),
    candidates~,
    parent=xtid("parent"),
    workflow="wf-1",
    at_ms=5000L,
    expected_revision=3L,
  ).unwrap()
  let proposal = @domain.BoardDomain::propose(state, xexpand(candidates~)).unwrap()
  assert_eq(Some(preview.record), proposal.next_state.expansion(xeid("exp-1")))
  assert_eq(preview.digest, preview.record.content_digest)
  assert_eq(state.revision(), 3L)
  assert_eq(
    x_rejection(proposal.next_state, xexpand(rev=4L)),
    @domain.DuplicateExpansion(expansion=xeid("exp-1")),
  )
  assert_eq(
    x_rejection(
      proposal.next_state,
      xexpand(candidates=[xcandidate(id="fresh", local_ref="fresh")], rev=4L),
    ),
    @domain.DuplicateExpansion(expansion=xeid("exp-1")),
  )
  assert_true(
    @domain.BoardDomain::preview_expand_graph(
      state.snapshot(),
      expansion=xeid("exp-1"),
      candidates~,
      parent=xtid("parent"),
      workflow="wf-1",
      at_ms=5000L,
      expected_revision=0L,
    )
    is Err(@domain.RevisionConflict(..)),
  )
}

///|
test "digest binds exact content lineage all tasks allocation and order" {
  let a = xcandidate()
  let b = xcandidate(id="later", local_ref="later")
  let digest = @domain.expansion_content_digest(
    expansion=xeid("exp-1"),
    candidates=[a, b],
    parent=xtid("parent"),
    workflow="wf-1",
  )
  for
    candidates in [
      [b, a],
      [a],
      [a, xcandidate(id="later", local_ref="later", title="changed")],
      [a, xcandidate(id="fresh", local_ref="later")],
      [a, xcandidate(id="later", local_ref="new")],
      [a, xcandidate(id="later", local_ref="later", deps=["parent"])],
    ] {
    assert_false(
      @domain.expansion_content_digest(
        expansion=xeid("exp-1"),
        candidates~,
        parent=xtid("parent"),
        workflow="wf-1",
      ) ==
      digest,
    )
  }
  assert_false(
    @domain.expansion_content_digest(
      expansion=xeid("other"),
      candidates=[a, b],
      parent=xtid("parent"),
      workflow="wf-1",
    ) ==
    digest,
  )
  assert_false(
    @domain.expansion_content_digest(
      expansion=xeid("exp-1"),
      candidates=[a, b],
      parent=xtid("other"),
      workflow="wf-1",
    ) ==
    digest,
  )
  assert_false(
    @domain.expansion_content_digest(
      expansion=xeid("exp-1"),
      candidates=[a, b],
      parent=xtid("parent"),
      workflow="wf-2",
    ) ==
    digest,
  )
}
