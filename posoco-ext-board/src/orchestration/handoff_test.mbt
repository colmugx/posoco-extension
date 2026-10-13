///|
async test "exact handle handoff survives cancellation during protected reservation" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter(block=true, delay_gate=true)
    let journal = orch_journal(hold_at=1)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let delivered : Array[@execution.BoardExecutionHandle] = []
    let dispatch = group.spawn(() => {
      scheduler.dispatch_next(on_admitted=handle => delivered.push(handle))
    })
    journal.entered.get()
    dispatch.cancel()
    assert_true(delivered.is_empty())
    journal.release.put(())
    assert_true(
      dispatch.wait()
      is Err(@orchestration.DispatchCancelled(cleanup_confirmed=true)),
    )
    assert_eq(delivered.length(), 1)
    assert_eq(delivered[0].execution_id(), owner.bindings()[0].execution_id)
    assert_eq(delivered[0].wait().phase, @execution.Unresolved)
    assert_eq(adapter.effects, 0)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}
