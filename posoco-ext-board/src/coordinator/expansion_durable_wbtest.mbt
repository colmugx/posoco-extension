///|
/// S4E1 durable-coordinator regression tests: one propose, one persist, one
/// authoritative event, the durable expansion history query, duplicate
/// identity rejection and the no-automatic-replay reconciliation rule.
/// Store scripting helpers come from the durable white-box test file.

///|
fn xexp_expand_command(
  seed : @domain.BoardStateSnapshot,
  rev~ : Int64 = -1L,
  expansion~ : String = "exp-1",
  task~ : String = "child",
  parent~ : String = "p1",
  workflow~ : String = "wf-1",
  at~ : Int64 = 5000L,
) -> @domain.BoardCommand {
  @domain.ExpandGraph(
    expansion=@domain.ExpansionId(expansion),
    candidates=[
      @domain.GraphTask::from_record(
        id=cid(task),
        title="expanded \{task}",
        description="atomic candidate",
        priority=@domain.High,
        definition_of_done=["durable"],
        dependencies=[cid("later")],
        local_ref="plan/\{task}",
      ),
      @domain.GraphTask::from_record(
        id=cid("later"),
        title="later",
        description="",
        priority=@domain.Normal,
        definition_of_done=[],
        dependencies=[cid(parent)],
        local_ref="plan/later",
      ),
    ],
    parent=cid(parent),
    workflow~,
    at_ms=at,
    expected_revision=if rev < 0L { seed.revision } else { rev },
  )
}

///|
/// The snapshot a seeded one-revision board would commit for the command.
fn xexp_candidate(
  seed : @domain.BoardStateSnapshot,
  command : @domain.BoardCommand,
) -> @domain.BoardStateSnapshot {
  let state = match @domain.BoardState::from_snapshot(seed) {
    Ok(state) => state
    Err(_) => abort("expansion test seed is invalid")
  }
  match @domain.BoardDomain::propose(state, command) {
    Ok(proposal) => proposal.next_state.snapshot()
    Err(_) => abort("expansion test proposal failed")
  }
}

///|
async test "expand graph commits durably with one persist and one event" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let seeded = snapshot_of(1L, [task_record("p1", @domain.Created, 10L)], [])
    store.loads.push_back(LoadOk(load_of(seeded)))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    let command = xexp_expand_command(seeded)
    let events = match coordinator.submit(command~) {
      Ok(events) => events
      Err(_) => fail("expected the expansion to commit")
    }
    // Exactly one authoritative event, at revision + 1.
    assert_eq(events.length(), 1)
    guard events[0]
      is @domain.GraphExpanded(
        expansion~,
        tasks~,
        parent~,
        workflow~,
        mapping~,
        digest~,
        at_ms~
      ) else {
      fail("expected GraphExpanded")
    }
    assert_eq(expansion, @domain.ExpansionId("exp-1"))
    assert_eq(tasks.length(), 2)
    assert_eq(tasks[0].id, cid("child"))
    assert_eq(parent, cid("p1"))
    assert_eq(workflow, "wf-1")
    assert_eq(mapping.length(), 2)
    assert_eq(mapping[0].local_ref, "plan/child")
    assert_true(digest.has_prefix("sha256:"))
    assert_eq(at_ms, 5000L)
    assert_eq(coordinator.revision(), Ok(2L))
    // One store transaction carried the whole expansion.
    assert_eq(store.persist_attempts, 1)
    assert_eq(store.committed_writes.length(), 1)
    assert_eq(store.committed_writes[0].revision, 2L)
    assert_eq(store.committed_writes[0].events, events)
    assert_eq(store.journal.length(), 1)
    // The durable history query answers the committed record.
    assert_eq(coordinator.expansions().unwrap().length(), 1)
    assert_eq(coordinator.expansions().unwrap()[0].mapping.length(), 2)
    let record = coordinator.expansions().unwrap()[0]
    assert_eq(record.expansion_id, @domain.ExpansionId("exp-1"))
    assert_eq(record.mapping[0].task_id, cid("child"))
    assert_eq(record.parent_task_id, cid("p1"))
    assert_eq(record.mapping[0].local_ref, "plan/child")
    assert_eq(record.workflow_id, "wf-1")
    assert_eq(record.content_digest, digest)
    // The candidate is committed in stage Created; no attempt exists.
    let task = coordinator.task(id=cid("child")).unwrap().unwrap()
    assert_eq(task.stage, @domain.Created)
    assert_eq(task.ready_since_ms, None)
    assert_eq(coordinator.attempts().unwrap(), [])
    coordinator.shutdown()
  })
}

///|
async test "a committed expansion id rejects every reuse through the coordinator" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let seeded = snapshot_of(1L, [task_record("p1", @domain.Created, 10L)], [])
    store.loads.push_back(LoadOk(load_of(seeded)))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    let _ = coordinator.submit(command=xexp_expand_command(seeded))
    // Same identity, same content: never replayed automatically.
    assert_eq(
      coordinator.submit(command=xexp_expand_command(seeded, rev=2L)),
      Err(
        Rejected(
          @domain.DuplicateExpansion(expansion=@domain.ExpansionId("exp-1")),
        ),
      ),
    )
    // Same identity, conflicting content: the same typed rejection.
    let conflicting = @domain.ExpandGraph(
      expansion=@domain.ExpansionId("exp-1"),
      candidates=[
        @domain.GraphTask::from_record(
          id=cid("other"),
          title="conflicting",
          description="",
          priority=@domain.Low,
          definition_of_done=[],
          dependencies=[],
          local_ref="plan/other",
        ),
      ],
      parent=cid("p1"),
      workflow="wf-1",
      at_ms=6000L,
      expected_revision=2L,
    )
    assert_eq(
      coordinator.submit(command=conflicting),
      Err(
        Rejected(
          @domain.DuplicateExpansion(expansion=@domain.ExpansionId("exp-1")),
        ),
      ),
    )
    // The rejections wrote nothing.
    assert_eq(store.persist_attempts, 1)
    assert_eq(coordinator.expansions().unwrap().length(), 1)
    assert_eq(coordinator.expansions().unwrap()[0].mapping.length(), 2)
    coordinator.shutdown()
  })
}

///|
async test "uncertain durability that landed adopts the candidate and never replays" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let seeded = snapshot_of(1L, [task_record("p1", @domain.Created, 10L)], [])
    store.loads.push_back(LoadOk(load_of(seeded)))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    let command = xexp_expand_command(seeded)
    let landed = xexp_candidate(seeded, command)
    // The persist crosses its visibility boundary ambiguously, but the
    // authoritative board already carries the landed expansion.
    store.persists.push_back(StepUncertain("injected post-rename failure"))
    store.loads.push_back(LoadOk(load_of(landed)))
    let outcome = coordinator.submit(command~)
    assert_true(outcome is Err(DurabilityUncertain(_)))
    // The candidate committed exactly once: adopted, not re-persisted.
    // No automatic replay: still exactly one persist attempt.
    assert_eq(store.persist_attempts, 1)
    assert_eq(coordinator.revision(), Ok(2L))
    assert_eq(coordinator.expansions().unwrap().length(), 1)
    assert_eq(coordinator.expansions().unwrap()[0].mapping.length(), 2)
    assert_eq(coordinator.status(), Ready)
    // A resubmission of the committed identity is a typed rejection, even
    // with the now-current revision expectation.
    assert_eq(
      coordinator.submit(command=xexp_expand_command(seeded, rev=2L)),
      Err(
        Rejected(
          @domain.DuplicateExpansion(expansion=@domain.ExpansionId("exp-1")),
        ),
      ),
    )
    assert_eq(store.persist_attempts, 1)
    coordinator.shutdown()
  })
}

///|
async test "uncertain durability that never landed keeps the prior board" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let seeded = snapshot_of(1L, [task_record("p1", @domain.Created, 10L)], [])
    store.loads.push_back(LoadOk(load_of(seeded)))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    let command = xexp_expand_command(seeded)
    // The persist failed ambiguously and the reload proves the write never
    // became visible: the prior committed board stands.
    store.persists.push_back(StepUncertain("injected ambiguous failure"))
    store.loads.push_back(LoadOk(load_of(seeded)))
    let outcome = coordinator.submit(command~)
    assert_true(outcome is Err(DurabilityUncertain(_)))
    assert_eq(store.persist_attempts, 1)
    assert_eq(coordinator.revision(), Ok(1L))
    assert_eq(coordinator.expansions().unwrap(), [])
    assert_eq(coordinator.task(id=cid("child")).unwrap(), None)
    assert_eq(coordinator.status(), Ready)
    coordinator.shutdown()
  })
}

///|
async test "a durable expansion survives restart with its history intact" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let seeded = snapshot_of(1L, [task_record("p1", @domain.Created, 10L)], [])
    store.loads.push_back(LoadOk(load_of(seeded)))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    let _ = coordinator.submit(command=xexp_expand_command(seeded))
    coordinator.shutdown()
    // A fresh attach restores the expansion history and the Created task.
    let again = scripted_coordinator(store, now_ms=() => 9000L)
    again.attach(group~)
    assert_true(again.wait_ready() is Ok(_))
    assert_eq(again.revision(), Ok(2L))
    let history = again.expansions().unwrap()
    assert_eq(history.length(), 1)
    assert_eq(history[0].expansion_id, @domain.ExpansionId("exp-1"))
    assert_eq(
      again.task(id=cid("child")).unwrap().unwrap().stage,
      @domain.Created,
    )
    // The restore normalized nothing: no running work existed.
    assert_eq(store.persist_attempts, 1)
    again.shutdown()
  })
}
