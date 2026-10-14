///|
async test "admission skips unavailable free drivers without blocking healthy slots" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 2)
    let unavailable = controlled(available=false)
    let healthy = controlled(block=true)
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=journal(),
      adapter_factory=slot => if slot == 0 { unavailable } else { healthy },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    assert_true(owner.status().host_available)
    assert_eq(owner.status().available_slots, 1)
    let handle = owner
      .execute(slot_request(task=1, attempt="attempt-1", execution=1))
      .unwrap()
    healthy.entered.get()
    assert_eq(unavailable.calls, 0)
    assert_eq(healthy.effects, 1)
    assert_eq(owner.status().available_slots, 0)
    assert_false(owner.status().host_available)
    assert_true(
      owner.execute(slot_request(task=2, attempt="attempt-2", execution=2))
      is Err(@execution.NotReady),
    )
    assert_eq(owner.bindings().length(), 1)
    healthy.release.put(())
    assert_eq(handle.wait().phase, @execution.Settled)
    assert_true(owner.status().host_available)
    assert_eq(owner.status().available_slots, 1)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "shutdown withdraws occupied runs even while another reservation is held" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 2)
    let store = held_journal(block_write=4, signal_write=99)
    let drivers : Array[ControlledAdapter] = []
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store~,
      adapter_factory=_ => {
        let driver = controlled(block=true)
        drivers.push(driver)
        driver
      },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let first = owner
      .execute(slot_request(task=1, attempt="attempt-1", execution=1))
      .unwrap()
    drivers[0].entered.get()
    let reservation = group.spawn(() => {
      owner.execute(slot_request(task=2, attempt="attempt-2", execution=2))
    })
    store.entered.get()
    assert_true(owner.status().admission_busy)
    assert_false(owner.shutdown(timeout_ms=10))
    assert_true(owner.status().closed)
    assert_eq(owner.status().available_slots, 0)
    store.release.put(())
    assert_true(reservation.wait() is Err(@execution.Closed))
    // No release of the first driver: shutdown itself must cancel its lifetime.
    let binding = first.wait()
    assert_eq(binding.outcome, Some(@execution.Cancelled))
    assert_eq(binding.phase, @execution.Unresolved)
    assert_true(owner.status().unresolved)
    assert_eq(drivers[1].calls, 0)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}
