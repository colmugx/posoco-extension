///|
async test "optional reservation revision and policy guards reject before journal and receive detached state" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let storage = journal()
    let adapter = controlled()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=storage,
    )
    assert_true(owner.attach(group) is Ok(_))
    let revision = backend.state().unwrap().revision
    assert_true(
      owner.execute(request(), reservation_revision=revision - 1L)
      is Err(@execution.IneligibleAttempt),
    )
    assert_true(
      owner.execute(request(), admission_guard=_ => false)
      is Err(@execution.IneligibleAttempt),
    )
    assert_eq(storage.writes, 0)
    assert_true(owner.bindings().is_empty())
    assert_eq(adapter.calls, 0)
    let observed : Array[(Int, Int)] = []
    let handle = owner
      .execute(request(), reservation_revision=revision, admission_guard=snapshot => {
        observed.push((snapshot.tasks.length(), snapshot.attempts.length()))
        snapshot.tasks.clear()
        snapshot.attempts.clear()
        true
      })
      .unwrap()
    assert_eq(handle.wait().phase, @execution.Settled)
    assert_eq(observed, [(1, 1), (1, 1)])
    assert_eq(adapter.effects, 1)
    assert_eq(backend.state().unwrap().tasks.length(), 1)
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Succeeded)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}
