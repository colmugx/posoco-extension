///|
fn x_task(id : String) -> @domain.BoardTask {
  @domain.BoardTask::from_record(
    id=@domain.BoardTaskId(id),
    title=id,
    description="",
    stage=@domain.Created,
    priority=@domain.Normal,
    definition_of_done=[],
    dependencies=[],
    created_at_ms=1L,
    updated_at_ms=1L,
    ready_since_ms=None,
  )
}

///|
fn x_proposal() -> @domain.BoardProposal {
  let state = @domain.BoardState::from_snapshot({
    revision: 1L,
    tasks: [x_task("parent")],
    attempts: [],
    expansions: [],
  }).unwrap()
  let candidates = [
    @domain.GraphTask::from_record(
      id=@domain.BoardTaskId("a"),
      title="A",
      description="",
      priority=@domain.High,
      definition_of_done=["ok"],
      dependencies=[@domain.BoardTaskId("b")],
      local_ref="first",
    ),
    @domain.GraphTask::from_record(
      id=@domain.BoardTaskId("b"),
      title="B",
      description="",
      priority=@domain.Normal,
      definition_of_done=[],
      dependencies=[@domain.BoardTaskId("parent")],
      local_ref="second",
    ),
  ]
  @domain.BoardDomain::propose(
    state,
    @domain.ExpandGraph(
      expansion=@domain.ExpansionId("proposal"),
      candidates~,
      parent=@domain.BoardTaskId("parent"),
      workflow="workflow",
      at_ms=10L,
      expected_revision=1L,
    ),
  ).unwrap()
}

///|
test "snapshot v2 and journal preserve complete proposal identity and forward DAG" {
  let proposal = x_proposal()
  let snapshot = proposal.next_state.snapshot()
  let encoded = encode_snapshot(snapshot).unwrap()
  assert_eq(decode_snapshot(encoded), Ok(snapshot))
  assert_eq(snapshot.expansions.length(), 1)
  assert_eq(snapshot.expansions[0].mapping.length(), 2)
  let event = proposal.events[0]
  assert_eq(decode_event(encode_event(event).unwrap()), Ok(event))
  let record : JournalRecord = { schema_version: 1, revision: 2L, event, }
  assert_eq(
    decode_journal_record(encode_journal_record(record).unwrap()),
    Ok(record),
  )
}

///|
test "v1 S3 snapshots load but v2 missing or ambiguous history fails closed" {
  let v1 = "{\"schema_version\":1,\"revision\":\"7\",\"tasks\":[],\"attempts\":[]}"
  let old = decode_snapshot(v1).unwrap()
  assert_eq(old.revision, 7L)
  assert_eq(old.expansions, [])
  assert_eq(decode_snapshot(encode_snapshot(old).unwrap()), Ok(old))
  let snapshot = x_proposal().next_state.snapshot()
  let base = match snapshot_json(snapshot) {
    Json::Object(f) => f
    _ => abort("object")
  }
  let missing = base.copy()
  let _ = missing.remove("expansions")
  assert_true(
    decode_snapshot(Json::object(missing).stringify()) is Err(InvalidData(_)),
  )
  let ambiguous = base.copy()
  ambiguous["schema_version"] = Json::number(1)
  assert_true(
    decode_snapshot(Json::object(ambiguous).stringify()) is Err(InvalidData(_)),
  )
  let null_history = base.copy()
  null_history["expansions"] = Json::null()
  assert_true(
    decode_snapshot(Json::object(null_history).stringify())
    is Err(InvalidData(_)),
  )
}

///|
test "v2 rejects damaged workflow mappings digest references and duplicate identities" {
  let snapshot = x_proposal().next_state.snapshot()
  let base = match expansion_json(snapshot.expansions[0]) {
    Json::Object(f) => f
    _ => abort("object")
  }
  let damaged : Array[Json] = []
  for
    pair in [
      ("workflow_id", Json::null()),
      ("workflow_id", Json::string(" ")),
      ("mapping", Json::array([])),
      ("content_digest", Json::string("fnv1a64:0123456789abcdef")),
      ("parent_task_id", Json::string("ghost")),
      ("mapping", Json::array([{ "local_ref": "first", "task_id": "ghost" }])),
      (
        "mapping",
        Json::array([
          { "local_ref": "first", "task_id": "a" },
          { "local_ref": "first", "task_id": "b" },
        ]),
      ),
      (
        "mapping",
        Json::array([
          { "local_ref": "first", "task_id": "a" },
          { "local_ref": "second", "task_id": "a" },
        ]),
      ),
    ] {
    let f = base.copy()
    f[pair.0] = pair.1
    damaged.push(Json::object(f))
  }
  let missing = base.copy()
  let _ = missing.remove("mapping")
  damaged.push(Json::object(missing))
  for record in damaged {
    let f = match snapshot_json(snapshot) {
      Json::Object(f) => f
      _ => abort("object")
    }
    f["expansions"] = Json::array([record])
    assert_true(
      decode_snapshot(Json::object(f).stringify()) is Err(InvalidData(_)),
    )
  }
  assert_true(
    encode_snapshot({
      ..snapshot,
      expansions: [snapshot.expansions[0], snapshot.expansions[0]],
    })
    is Err(InvalidData(_)),
  )
}

///|
async test "one store transaction durably contains every node and one audit event" {
  let proposal = x_proposal()
  let store = MemoryBoardStore::MemoryBoardStore()
  assert_eq(
    store.persist(proposal.next_state.snapshot(), proposal.events),
    Ok(()),
  )
  let loaded = store.load().unwrap()
  assert_eq(loaded.snapshot, proposal.next_state.snapshot())
  assert_eq(loaded.journal.length(), 1)
  assert_eq(loaded.journal[0].event, proposal.events[0])
}
