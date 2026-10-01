///|
test "public snapshot codec and pure recovery boundary" {
  let snapshot = @store.empty_snapshot()
  let wire = @store.encode_snapshot(snapshot).unwrap()
  assert_eq(@store.decode_snapshot(wire), Ok(snapshot))
  let recovery = @store.recover_snapshot(snapshot, at_ms=123L).unwrap()
  assert_eq(recovery.snapshot, snapshot)
  assert_eq(recovery.events, [])
}

///|
async test "public BoardStore trait memory and load recover persist" {
  let memory = @store.MemoryBoardStore::MemoryBoardStore()
  let store : &@store.BoardStore = memory
  assert_eq(store.persist(@store.empty_snapshot(), []), Ok(()))
  assert_eq(
    store.load().map(loaded => loaded.snapshot),
    Ok(@store.empty_snapshot()),
  )
  let recovery = @store.load_recover_persist(store, at_ms=123L).unwrap()
  assert_eq(recovery.snapshot.revision, 0L)
  assert_eq(memory.load().unwrap().journal.map(record => record.event), [])
}

///|
test "public domain record factory and detached snapshot codec roundtrip" {
  let dod = ["verified"]
  let dependencies : Array[@domain.BoardTaskId] = []
  let task = @domain.BoardTask::from_record(
    id=@domain.BoardTaskId::BoardTaskId("t"),
    title="task",
    description="full detached record",
    stage=@domain.Ready,
    priority=@domain.High,
    definition_of_done=dod,
    dependencies~,
    created_at_ms=0L,
    updated_at_ms=9007199254740993L,
    ready_since_ms=Some(9223372036854775807L),
  )
  let attempt = @domain.Attempt::from_record(
    id=@domain.AttemptId::AttemptId("a"),
    task_id=task.id,
    kind=@domain.Review,
    status=@domain.Succeeded,
    review=Some(@domain.Approved),
    created_at_ms=1L,
    started_at_ms=Some(2L),
    finished_at_ms=Some(3L),
    updated_at_ms=3L,
  )
  let source : @domain.BoardStateSnapshot = {
    revision: 9007199254740993L,
    tasks: [task],
    attempts: [attempt],
  }
  dod.clear()
  dependencies.push(task.id)
  assert_eq(task.definition_of_done, ["verified"])
  assert_eq(task.dependencies, [])
  let wire = @store.encode_snapshot(source).unwrap()
  let restored : @domain.BoardStateSnapshot = @store.decode_snapshot(wire).unwrap()
  assert_eq(restored, source)
  let copied = restored.copy_detached()
  restored.tasks[0].definition_of_done.clear()
  restored.tasks[0].dependencies.push(task.id)
  restored.tasks.clear()
  restored.attempts.clear()
  assert_eq(copied, source)
}
