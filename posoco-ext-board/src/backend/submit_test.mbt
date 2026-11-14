///|
async test "typed headless preparation keeps legal transitions and optimistic revisions" {
  @async.with_task_group(group => {
    let backend = backend_with_parent(group)
    assert_true(
      backend.submit(
        @domain.MoveTask(
          id=@domain.BoardTaskId("t1"),
          to=@domain.Ready,
          at_ms=6000L,
          expected_revision=1L,
        ),
      )
      is Err(_),
    )
    assert_eq(backend.state().unwrap().revision, 1L)
    ignore(
      backend
      .submit(
        @domain.MoveTask(
          id=@domain.BoardTaskId("t1"),
          to=@domain.Refining,
          at_ms=6000L,
          expected_revision=1L,
        ),
      )
      .unwrap(),
    )
    assert_true(
      backend.submit(
        @domain.MoveTask(
          id=@domain.BoardTaskId("t1"),
          to=@domain.Ready,
          at_ms=6001L,
          expected_revision=1L,
        ),
      )
      is Err(_),
    )
    ignore(
      backend
      .submit(
        @domain.MoveTask(
          id=@domain.BoardTaskId("t1"),
          to=@domain.Ready,
          at_ms=6001L,
          expected_revision=2L,
        ),
      )
      .unwrap(),
    )
    ignore(
      backend
      .submit(
        @domain.QueueAttempt(
          id=@domain.AttemptId("host-execute"),
          task=@domain.BoardTaskId("t1"),
          kind=@domain.Execute,
          at_ms=6002L,
          expected_revision=3L,
        ),
      )
      .unwrap(),
    )
    let snapshot = backend.state().unwrap()
    assert_eq(snapshot.revision, 4L)
    assert_eq(snapshot.tasks[0].stage, @domain.Ready)
    assert_eq(snapshot.attempts[0].status, @domain.Queued)
    assert_eq(backend.event_history().length(), 4)
    assert_eq(backend.current_seq(), 4L)
    backend.shutdown()
  })
}
