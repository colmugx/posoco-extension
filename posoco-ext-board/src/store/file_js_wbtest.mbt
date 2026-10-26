///|
async test "JS file storage preserves one atomic expansion and durable identity through restart" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  let store = FileBoardStore::at_directory(directory~)
  let state = @domain.BoardState::from_snapshot(fixture()).unwrap()
  let proposal = @domain.BoardDomain::propose(
    state,
    @domain.ExpandGraph(
      expansion=@domain.ExpansionId("node-expansion"),
      candidates=[
        @domain.GraphTask::from_record(
          id=tid("generated"),
          local_ref="new",
          title="Generated",
          description="",
          priority=@domain.Normal,
          definition_of_done=[],
          dependencies=[tid("b")],
        ),
      ],
      parent=tid("a"),
      workflow="node-workflow",
      at_ms=400L,
      expected_revision=17L,
    ),
  ).unwrap()
  ignore(
    store.persist(proposal.next_state.snapshot(), proposal.events).unwrap(),
  )
  let reloaded = FileBoardStore::at_directory(directory~).load().unwrap()
  assert_eq(reloaded.snapshot, proposal.next_state.snapshot())
  assert_eq(reloaded.journal.length(), 1)
  assert_eq(
    reloaded.snapshot.expansions[0].expansion_id.value,
    "node-expansion",
  )
}

///|
async test "JS all six file failure stages publish no partial graph and preserve visible uncertainty" {
  for
    stage in [
      TempWrite,
      TempFsync,
      JournalAppend,
      JournalFsync,
      Rename,
      DirectoryFsync,
    ] {
    let directory = @fixtures.temporary_directory()
    defer @fixtures.cleanup(directory)
    let normal = FileBoardStore::at_directory(directory~)
    let seed = fixture()
    ignore(normal.persist(seed, []).unwrap())
    let state = @domain.BoardState::from_snapshot(seed).unwrap()
    let candidate = @domain.BoardDomain::propose(
      state,
      @domain.CreateTask(
        id=tid("new"),
        title="New",
        description="",
        priority=@domain.Normal,
        definition_of_done=[],
        dependencies=[],
        user_story="",
        implementation_suggestions="",
        at_ms=400L,
        expected_revision=17L,
      ),
    ).unwrap()
    let failing = FileBoardStore::at_directory(directory~, fail_at=stage)
    let result = failing.persist(
      candidate.next_state.snapshot(),
      candidate.events,
    )
    let loaded = normal.load().unwrap()
    if stage == DirectoryFsync {
      assert_true(result is Err(DurabilityUncertain(_)))
      assert_eq(loaded.snapshot, candidate.next_state.snapshot())
    } else {
      assert_eq(result, Err(Injected(stage)))
      assert_eq(loaded.snapshot, seed)
    }
  }
}

///|
async test "JS store rejects symlinks and retains malformed audit evidence instead of replay" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  let store = FileBoardStore::at_directory(directory~)
  let seed = fixture()
  ignore(store.persist(seed, []).unwrap())
  @fixtures.put(directory + "/events.jsonl", "broken\n")
  assert_true(store.load() is Err(_))
  @fixtures.put(directory + "/events.jsonl", "{\"torn\"")
  assert_eq(store.load().unwrap().snapshot, seed)
  @fixtures.link(directory + "/board.json", directory + "/board.json.tmp")
  assert_true(store.persist(seed, []) is Err(_))
  assert_eq(store.load().unwrap().snapshot, seed)
}
