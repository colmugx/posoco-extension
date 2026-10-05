///|
async test "public coordinator restores durable revision after restart" {
  let store = @store.MemoryBoardStore()
  @async.with_task_group(group => {
    let first = @coordinator.BoardCoordinator(store~, now_ms=() => 100L)
    assert_eq(first.status(), @coordinator.Detached)
    first.attach(group~)
    assert_true(first.wait_ready() is Ok(_))
    assert_eq(first.status(), @coordinator.Ready)
    let command = @domain.CreateTask(
      id=@domain.BoardTaskId("restored"),
      title="durable",
      description="",
      priority=@domain.Normal,
      definition_of_done=[],
      dependencies=[],
      at_ms=10L,
      expected_revision=0L,
    )
    assert_true(first.submit(command~) is Ok(_))
    first.shutdown()
    assert_eq(first.status(), @coordinator.Stopped)
    let second = @coordinator.BoardCoordinator(store~, now_ms=() => 200L)
    second.attach(group~)
    assert_true(second.wait_ready() is Ok(_))
    assert_eq(second.revision(), Ok(1L))
    assert_eq(second.tasks().unwrap().length(), 1)
    assert_true(
      second.submit(
        command=@domain.MoveTask(
          id=@domain.BoardTaskId("restored"),
          to=@domain.Refining,
          at_ms=20L,
          expected_revision=1L,
        ),
      )
      is Ok(_),
    )
    assert_eq(second.revision(), Ok(2L))
    second.shutdown()
  })
}
