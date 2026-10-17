///|
/// White-box reconcile guards. The digest-contradiction freeze is not
/// reachable through public flows (the domain binds exactly one content
/// digest to a committed proposal identity), so the expected-digest
/// comparison is exercised directly on host internals.

///|
async fn wb_parent(backend : @backend.BoardBackend) -> Unit {
  assert_true(
    backend.handle_command({
      command_id: "create-parent",
      name: "board.task.create",
      expected_revision: 0L,
      args: {
        "id": "parent",
        "title": "Parent",
        "description": "",
        "priority": "normal",
        "definition_of_done": [],
        "dependencies": [],
      },
    }).accepted,
  )
}

///|
fn wb_candidate(id : String) -> @domain.GraphTask {
  @domain.GraphTask::from_record(
    id=@domain.BoardTaskId(id),
    title="Generated",
    description="plan only",
    priority=@domain.Normal,
    definition_of_done=["Reviewed"],
    dependencies=[@domain.BoardTaskId("parent")],
    local_ref=id,
  )
}

///|
fn wb_host(
  backend : @backend.BoardBackend,
  proposal_id~ : String,
  digest~ : String,
) -> ExpansionHost {
  {
    backend_: backend,
    policy_: ExpansionPolicy(),
    allocator_: NumberedExpansionAllocator(prefix="expanded-"),
    now_ms_: () => 100L,
    busy_: false,
    phase_: Uncertain,
    authorization_: Some(
      ExpansionAuthorization::ExpansionAuthorization(
        authorization_id="auth",
        workflow="workflow",
        workflow_parent="parent",
        workflow_task_scope=["parent"],
        permitted_existing_dependencies=["parent"],
        deadline_ms=1000L,
      ),
    ),
    draft_: Some({
      proposal_id,
      parent_task_id: "parent",
      base_revision: 2L,
      tasks: [
        {
          key: "a",
          title: "Generated",
          description: "plan only",
          priority: @domain.Normal,
          definition_of_done: ["Reviewed"],
          depends_on: [ExistingTask(id=@domain.BoardTaskId("parent"))],
        },
      ],
    }),
    preview_: None,
    approval_: None,
    mapping_: [],
    candidates_: [],
    expected_digest_: Some(digest),
  }
}

///|
async test "reconcile proves a matching record and freezes on contradiction" {
  @async.with_task_group(group => {
    let backend = @backend.BoardBackend(now_ms=() => 100L)
    backend.attach(group)
    wb_parent(backend)
    let events = backend
      .expand_graph(
        expansion=@domain.ExpansionId("proposal-1"),
        candidates=[wb_candidate("expanded-a")],
        parent=@domain.BoardTaskId("parent"),
        workflow="workflow",
        at_ms=Some(100L),
        expected_revision=1L,
      )
      .unwrap()
    assert_eq(events.length(), 1)
    let durable = backend.expansion_history().unwrap()[0].content_digest
    // Matching expectation: the uncertain host settles as committed, once.
    let settled = wb_host(backend, proposal_id="proposal-1", digest=durable)
    assert_eq(settled.reconcile().unwrap(), true)
    assert_eq(settled.phase(), Committed)
    assert_true(settled.reconcile() is Err(InvalidPhase))
    // Contradictory expectation: freeze as a conflict, never as success.
    let contradicted = wb_host(
      backend,
      proposal_id="proposal-1",
      digest="sha256:other",
    )
    assert_true(contradicted.reconcile() is Err(DigestConflict))
    assert_eq(contradicted.phase(), Conflict)
    backend.shutdown()
  })
}
