///|
async test "unconfirmed durable Start never admits provider effects even when uncertainty committed the attempt" {
  for uncertain in [false, true] {
    @async.with_task_group(group => {
      let storage : FailingBoardStorage = {
        inner: @store.MemoryBoardStore(),
        fail: false,
        uncertain,
        failures: 0,
      }
      let backend = prepared_board(group, store=storage)
      let adapter = controlled()
      let owner = @execution.BoardExecutionOwner(
        backend~,
        adapter~,
        store=journal(),
      )
      assert_true(owner.attach(group) is Ok(_))
      storage.fail = true
      assert_eq(
        owner.execute(request()).unwrap().wait().phase,
        @execution.Unresolved,
      )
      assert_eq(storage.failures, 1)
      assert_eq(adapter.effects, 0)
      let state = backend.state().unwrap()
      assert_eq(state.revision, if uncertain { 3L } else { 2L })
      assert_eq(
        state.attempts[0].status,
        if uncertain {
          @domain.Running
        } else {
          @domain.Queued
        },
      )
      assert_eq(
        backend
        .event_history()
        .filter(e => e.kind == "board.attempt.started")
        .length(),
        if uncertain {
          1
        } else {
          0
        },
      )
      assert_eq(
        backend
        .event_history()
        .filter(e => e.kind == "board.attempt.finished")
        .length(),
        0,
      )
      assert_true(owner.shutdown())
      backend.shutdown()
    })
  }
}

///|
async test "immediate cancellation before worker entry never launches an Agent or marks attempt cancelled prematurely" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let adapter = controlled()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let handle = owner.execute(request()).unwrap()
    assert_true(owner.cancel("exec") is Ok(_))
    let binding = handle.wait()
    assert_eq(adapter.calls, 0)
    assert_eq(binding.phase, @execution.Unresolved)
    assert_eq(binding.outcome, Some(@execution.Cancelled))
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Queued)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}
