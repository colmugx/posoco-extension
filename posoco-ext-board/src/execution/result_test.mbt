///|
async test "scoped Agent text result is bounded one-shot and only readable by exact settled binding" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let store = @execution.MemoryBoardExecutionStore()
    let model = probe()
    let channel = @execution.BoardExecutionResultChannel(max_chars=32)
    let driver = @execution.PosocoBoardExecutionAdapter(
      extensions=() => [model],
      result_channel=channel,
    )
    let owner = @execution.BoardExecutionOwner(backend~, adapter=driver, store~)
    assert_true(owner.attach(group) is Ok(_))
    let binding = owner.execute(request()).unwrap().wait()
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Completed))
    assert_eq(channel.take({ ..binding, execution_id: "other", }), None)
    assert_eq(channel.take({ ..binding, task_id: "other", }), None)
    assert_eq(channel.take({ ..binding, attempt_id: "other", }), None)
    assert_eq(channel.take({ ..binding, session_id: "other", }), None)
    assert_eq(channel.take({ ..binding, phase: @execution.Finished, }), None)
    assert_eq(
      channel.take({ ..binding, outcome: Some(@execution.Failed), }),
      None,
    )
    let run = binding.run.unwrap()
    assert_eq(
      channel.take({ ..binding, run: Some({ ..run, turn_id: "other", }), }),
      None,
    )
    assert_false(driver.ready())
    assert_eq(channel.take(binding), Some("done"))
    assert_eq(channel.take(binding), None)
    assert_true(driver.ready())
    assert_eq(store.load().unwrap()[0], binding)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "oversized Agent output completes the turn but never enters the result channel" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let model = probe()
    let channel = @execution.BoardExecutionResultChannel(max_chars=3)
    let driver = @execution.PosocoBoardExecutionAdapter(
      extensions=() => [model],
      result_channel=channel,
    )
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=@execution.MemoryBoardExecutionStore(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let binding = owner.execute(request()).unwrap().wait()
    assert_eq(binding.phase, @execution.Settled)
    // The Agent turn itself completed, so the S4A completion mapping stays
    // Completed even though the oversized ephemeral output was not captured.
    // The failure is not hidden: the channel stays empty, so a planning
    // consumer observes a missing result for this exact settled binding.
    assert_eq(binding.outcome, Some(@execution.Completed))
    assert_eq(channel.take(binding), None)
    assert_eq(channel.take(binding), None)
    assert_eq(model.stopped, 1)
    // The failed capture never occupied the channel; it stays usable.
    assert_true(driver.ready())
    assert_true(owner.shutdown())
    backend.shutdown()
  })
  let invalid = @execution.BoardExecutionResultChannel(max_chars=0)
  let driver = @execution.PosocoBoardExecutionAdapter(
    extensions=() => [],
    result_channel=invalid,
  )
  assert_false(driver.ready())
}
