///|
struct GatedJournal {
  inner : @execution.MemoryBoardExecutionStore
  mut writes : Int32
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
impl @execution.BoardExecutionStore for GatedJournal with fn load(self) {
  self.inner.load()
}

///|
impl @execution.BoardExecutionStore for GatedJournal with fn persist(
  self,
  records,
) {
  self.writes += 1
  if self.writes == 6 {
    self.entered.put(())
    self.release.get()
  }
  self.inner.persist(records)
}

///|
async test "shutdown cannot release journal while new admission is in flight behind a completed previous worker" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let adapter = controlled()
    let store : GatedJournal = {
      inner: @execution.MemoryBoardExecutionStore(),
      writes: 0,
      entered: @aqueue.Queue(kind=Unbounded),
      release: @aqueue.Queue(kind=Unbounded),
    }
    let owner = @execution.BoardExecutionOwner(backend~, adapter~, store~)
    assert_true(owner.attach(group) is Ok(_))
    assert_eq(
      owner.execute(request()).unwrap().wait().phase,
      @execution.Settled,
    )
    assert_true(
      backend.handle_command({
        command_id: "second",
        name: "board.attempt.queue",
        expected_revision: 4L,
        args: { "id": "second", "task_id": "task", "kind": "execute" },
      }).accepted,
    )
    let admission = group.spawn(() => {
      owner.execute({
        ..request(),
        attempt_id: "second",
        execution_id: "second",
        session_id: "second",
      })
    })
    store.entered.get()
    assert_false(owner.shutdown())
    store.release.put(())
    assert_true(admission.wait() is Err(@execution.Closed))
    assert_eq(adapter.calls, 1)
    assert_eq(
      backend.state().unwrap().attempts.filter(a => a.id.value == "second")[0].status,
      @domain.Queued,
    )
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}
