///|
/// S4E1 native store integration: one real FileBoardStore transaction carries
/// the whole GraphExpanded graph plus its durable ExpansionRecord, a fresh
/// store reloads both after restart and recovery, recovered boards reject
/// duplicate identity reuse, and every injected persistence stage keeps the
/// graph atomic across the visibility boundary. The journal stays audit-only
/// and is never replayed into state.

///|
fn native_candidates() -> Array[@domain.GraphTask] {
  [
    @domain.GraphTask::from_record(
      id=tid("c1"),
      title="expanded one 🙂",
      description="atomic whole-graph candidate",
      priority=@domain.High,
      definition_of_done=["durable"],
      dependencies=[tid("c2"), tid("b")],
      local_ref="plan/one",
    ),
    @domain.GraphTask::from_record(
      id=tid("c2"),
      title="expanded two",
      description="",
      priority=@domain.Normal,
      definition_of_done=[],
      dependencies=[tid("b")],
      local_ref="plan/two",
    ),
  ]
}

///|
fn native_expand_command(
  expected_revision~ : Int64,
  expansion~ : String = "s4e1-native",
) -> @domain.BoardCommand {
  @domain.ExpandGraph(
    expansion=@domain.ExpansionId(expansion),
    candidates=native_candidates(),
    parent=tid("b"),
    workflow="workflow",
    at_ms=50L,
    expected_revision~,
  )
}

///|
fn native_proposal() -> @domain.BoardProposal {
  let state = @domain.BoardState::from_snapshot(fixture()).unwrap()
  @domain.BoardDomain::propose(
    state,
    native_expand_command(expected_revision=17L),
  ).unwrap()
}

///|
async test "native file store commits one atomic expansion and reloads the durable record" {
  let root = @fs.tmpdir(prefix="board-s4e1-native-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let store = FileBoardStore::FileBoardStore(root~)
  assert_eq(store.persist(fixture(), []), Ok(()))
  let proposal = native_proposal()
  // One propose emits exactly one authoritative GraphExpanded fact.
  assert_eq(proposal.events.length(), 1)
  guard proposal.events[0]
    is @domain.GraphExpanded(
      expansion~,
      tasks~,
      parent~,
      workflow~,
      mapping~,
      digest~,
      at_ms~
    ) else {
    fail("expected one GraphExpanded fact")
  }
  assert_eq(expansion, @domain.ExpansionId("s4e1-native"))
  assert_eq(parent, tid("b"))
  assert_eq(workflow, "workflow")
  assert_eq(at_ms, 50L)
  assert_eq(mapping, [
    { local_ref: "plan/one", task_id: tid("c1"), },
    { local_ref: "plan/two", task_id: tid("c2"), },
  ])
  assert_eq(tasks.length(), 2)
  for task in tasks {
    assert_eq(task.stage, @domain.Created)
    assert_eq(task.ready_since_ms, None)
    assert_eq(task.created_at_ms, 50L)
  }
  assert_true(@domain.valid_expansion_digest(digest))
  assert_eq(
    store.persist(proposal.next_state.snapshot(), proposal.events),
    Ok(()),
  )
  assert_false(@fs.exists(data + "/board.json.tmp"))
  // Restart: a fresh native store reloads the authoritative board verbatim.
  let reloaded = FileBoardStore::FileBoardStore(root~)
  let loaded = reloaded.load().unwrap()
  assert_eq(loaded.snapshot, proposal.next_state.snapshot())
  assert_eq(loaded.snapshot.revision, 18L)
  assert_eq(loaded.snapshot.tasks.length(), 4)
  assert_eq(loaded.snapshot.attempts, fixture().attempts)
  // Both candidate tasks landed together with their forward edges.
  let created = loaded.snapshot.tasks.filter(task => {
    task.id == tid("c1") || task.id == tid("c2")
  })
  assert_eq(created.length(), 2)
  assert_eq(created[0].dependencies, [tid("c2"), tid("b")])
  assert_eq(created[1].dependencies, [tid("b")])
  // The durable record survives restart with its complete identity binding.
  assert_eq(loaded.snapshot.expansions.length(), 1)
  let record = loaded.snapshot.expansions[0]
  assert_eq(record.expansion_id, @domain.ExpansionId("s4e1-native"))
  assert_eq(record.parent_task_id, tid("b"))
  assert_eq(record.workflow_id, "workflow")
  assert_eq(record.mapping, mapping)
  assert_eq(record.content_digest, digest)
  assert_eq(record.created_at_ms, 50L)
  let board_text = @fs.read_file(data + "/board.json").text()
  assert_true(board_text.contains("s4e1-native"))
  assert_true(board_text.contains("plan/one"))
  // Exactly one audit record carries the whole graph; audit stays audit only.
  assert_eq(loaded.journal, records(18L, proposal.events))
  assert_eq(
    decode_journal_events(@fs.read_file(data + "/events.jsonl").text()),
    Ok(proposal.events),
  )
  // Loaded results are detached from the store.
  loaded.snapshot.expansions[0].mapping.clear()
  loaded.snapshot.tasks.clear()
  loaded.journal.clear()
  assert_eq(reloaded.load().unwrap().snapshot, proposal.next_state.snapshot())
  assert_eq(reloaded.load().unwrap().journal, records(18L, proposal.events))
}

///|
async test "native restart recovery keeps the expansion identity and rejects duplicate reuse durably" {
  let root = @fs.tmpdir(prefix="board-s4e1-duplicate-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let store = FileBoardStore::FileBoardStore(root~)
  assert_eq(store.persist(fixture(), []), Ok(()))
  let proposal = native_proposal()
  let expanded = proposal.next_state.snapshot()
  assert_eq(store.persist(expanded, proposal.events), Ok(()))
  // Real restart recovery: normalization touches only Running records and
  // passes the durable expansion history through verbatim.
  let recovered = load_recover_persist(
    FileBoardStore::FileBoardStore(root~),
    at_ms=100L,
  ).unwrap()
  assert_eq(recovered.snapshot.revision, 19L)
  assert_eq(recovered.snapshot.expansions, expanded.expansions)
  assert_eq(
    recovered.snapshot.tasks.filter(task => task.id == tid("a"))[0].stage,
    @domain.Suspended,
  )
  assert_eq(recovered.events, [
    @domain.TaskStageChanged(
      id=tid("a"),
      from=@domain.Running,
      to=@domain.Suspended,
      at_ms=100L,
    ),
    @domain.AttemptFinished(
      id=aid("x"),
      task_id=tid("a"),
      outcome=@domain.Interrupted,
      at_ms=100L,
    ),
  ])
  let expected : Array[JournalRecord] = records(18L, proposal.events)
  expected.append(records(19L, recovered.events))
  assert_eq(
    FileBoardStore::FileBoardStore(root~).load().unwrap().journal,
    expected,
  )
  let state = @domain.BoardState::from_snapshot(recovered.snapshot).unwrap()
  let board = @fs.read_file(data + "/board.json").binary()
  let journal = @fs.read_file(data + "/events.jsonl").binary()
  // Same identity, same content, now-current revision: typed rejection.
  let again = @domain.BoardDomain::propose(
    state,
    native_expand_command(expected_revision=19L),
  )
  guard again is Err(@domain.DuplicateExpansion(expansion~)) else {
    fail("expected the recovered identity to reject reuse")
  }
  assert_eq(expansion, @domain.ExpansionId("s4e1-native"))
  // Same identity, conflicting content: the same rejection, never a replay.
  let conflicting = @domain.BoardDomain::propose(
    state,
    @domain.ExpandGraph(
      expansion=@domain.ExpansionId("s4e1-native"),
      candidates=[
        @domain.GraphTask::from_record(
          id=tid("conflict"),
          title="conflicting",
          description="",
          priority=@domain.Low,
          definition_of_done=[],
          dependencies=[],
          local_ref="plan/conflict",
        ),
      ],
      parent=tid("b"),
      workflow="other",
      at_ms=60L,
      expected_revision=19L,
    ),
  )
  assert_true(conflicting is Err(@domain.DuplicateExpansion(..)))
  // The rejections are pure domain decisions: nothing durable changed.
  assert_eq(@fs.read_file(data + "/board.json").binary(), board)
  assert_eq(@fs.read_file(data + "/events.jsonl").binary(), journal)
  assert_false(@fs.exists(data + "/board.json.tmp"))
  assert_eq(
    FileBoardStore::FileBoardStore(root~).load().unwrap().snapshot,
    recovered.snapshot,
  )
}

///|
async test "all six native failure stages keep the expansion graph atomic including visible directory fsync uncertainty" {
  for
    stage in [
      TempWrite,
      TempFsync,
      JournalAppend,
      JournalFsync,
      Rename,
      DirectoryFsync,
    ] {
    let root = @fs.tmpdir(prefix="board-s4e1-stage-")
    defer @fs.rmdir(root, recursive=true)
    let data = root + "/.cetas/board/default"
    let good = FileBoardStore::FileBoardStore(root~)
    assert_eq(good.persist(fixture(), []), Ok(()))
    let seed_bytes = @fs.read_file(data + "/board.json").binary()
    let proposal = native_proposal()
    let expanded = proposal.next_state.snapshot()
    @fs.write_file(data + "/board.json.tmp", "stale temp")
    let failing = FileBoardStore::FileBoardStore(root~, fail_at=Some(stage))
    if stage == DirectoryFsync {
      // Rename is the visibility boundary: this failure lands after it, so
      // the outcome is uncertain, never a claimed rollback.
      match failing.persist(expanded, proposal.events) {
        Err(DurabilityUncertain(_)) => ()
        _ => fail("expected post-rename uncertainty")
      }
    } else {
      assert_eq(
        failing.persist(expanded, proposal.events),
        Err(Injected(stage)),
      )
    }
    assert_false(@fs.exists(data + "/board.json.tmp"))
    let restarted = FileBoardStore::FileBoardStore(root~)
    let loaded = restarted.load().unwrap()
    if stage == DirectoryFsync {
      // The whole graph is already authoritative and visible.
      assert_eq(loaded.snapshot, expanded)
    } else {
      // No partial graph: no candidate task, no record, no revision bump.
      assert_eq(loaded.snapshot, fixture())
      assert_eq(@fs.read_file(data + "/board.json").binary(), seed_bytes)
    }
    // Audit records may sit ahead of the authoritative board once the
    // journal synced; they are never replayed into state.
    let expected : Array[JournalRecord] = []
    if stage == JournalFsync || stage == Rename || stage == DirectoryFsync {
      expected.append(records(18L, proposal.events))
    }
    assert_eq(loaded.journal, expected)
    let state = @domain.BoardState::from_snapshot(loaded.snapshot).unwrap()
    if stage == DirectoryFsync {
      let outcome = @domain.BoardDomain::propose(
        state,
        native_expand_command(expected_revision=loaded.snapshot.revision),
      )
      guard outcome is Err(@domain.DuplicateExpansion(expansion~)) else {
        fail("the landed identity must reject reuse after uncertainty")
      }
      assert_eq(expansion, @domain.ExpansionId("s4e1-native"))
    } else {
      // The failed write left the board intact and the identity free.
      assert_true(
        @domain.BoardDomain::propose(
          state,
          native_expand_command(expected_revision=loaded.snapshot.revision),
        )
        is Ok(_),
      )
    }
    // A later write is an explicit new commit: audit facts may repeat and
    // the journal is still never replayed.
    assert_eq(good.persist(expanded, proposal.events), Ok(()))
    expected.append(records(18L, proposal.events))
    let after_retry = FileBoardStore::FileBoardStore(root~).load().unwrap()
    assert_eq(after_retry.snapshot, expanded)
    assert_eq(after_retry.journal, expected)
    assert_false(@fs.exists(data + "/board.json.tmp"))
  }
}
