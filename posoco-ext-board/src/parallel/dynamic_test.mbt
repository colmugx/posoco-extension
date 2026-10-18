///|
async fn controlled_wait_paused(h : ParallelHarness) -> Unit {
  for _ in 0..<2000 {
    if h.runner.status().phase is @workflow.Paused {
      return
    }
    if h.runner.status().phase is (Failed | Stopped | Completed | Unresolved) {
      break
    }
    @async.sleep(1)
  }
  fail("expected controlled boundary: \{Repr(h.runner.status())}")
}

///|
async test "controlled scope is append-only detached and inaccessible to ordinary static workflows" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["a", "b"])
    let selected = ["a"]
    ignore(
      h.runner
      .start_controlled(parallel_spec(scope=@workflow.Selected(selected)))
      .unwrap(),
    )
    selected.push("b")
    assert_eq(h.runner.authorized_scope(), ["a"])
    let view = h.runner.authorized_scope()
    view.clear()
    assert_eq(h.runner.authorized_scope(), ["a"])
    let revision = h.backend.state().unwrap().revision
    assert_true(
      h.runner.extend_scope(ids=["b"], expected_revision=revision - 1L)
      is Err(_),
    )
    assert_true(
      h.runner.extend_scope(ids=["missing"], expected_revision=revision)
      is Err(_),
    )
    assert_true(
      h.runner.extend_scope(ids=["b", "b"], expected_revision=revision)
      is Err(_),
    )
    ignore(
      h.runner.extend_scope(ids=["b"], expected_revision=revision).unwrap(),
    )
    ignore(
      h.runner.extend_scope(ids=["b"], expected_revision=revision).unwrap(),
    )
    assert_eq(h.runner.authorized_scope(), ["a", "b"])
    assert_eq(h.runner.status().remaining_executions, 10)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
    let ordinary = parallel_harness(group, tasks=["static"], hold=[
      "attempt-static-1",
    ])
    ignore(ordinary.runner.start(parallel_spec()).unwrap())
    assert_false(ordinary.runner.quiescent())
    assert_true(
      ordinary.runner.extend_scope(
        ids=["static"],
        expected_revision=ordinary.backend.state().unwrap().revision,
      )
      is Err(_),
    )
    assert_true(ordinary.runner.begin_planning() is Err(_))
    assert_true(ordinary.runner.shutdown())
    ordinary.backend.shutdown()
  })
}

///|
async test "controlled waves fan in fully before extending scope and never re-admit historical Attempts" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["a", "b", "c"], capacity=2, hold=[
      "attempt-a-1", "attempt-b-1",
    ])
    ignore(
      h.runner
      .start_controlled(
        parallel_spec(scope=@workflow.Selected(["a", "b"]), max_concurrency=2),
      )
      .unwrap(),
    )
    assert_true(h.runner.quiescent())
    assert_eq(h.shared.runs, 0)
    assert_true(h.runner.resume_workflow())
    parallel_yield_until(what="two running and held", check=() => {
      h.shared.active == 2 &&
      h.shared.holds.contains("attempt-a-1") &&
      h.shared.holds.contains("attempt-b-1")
    })
    let active = h.owner.status().active_bindings
    assert_true(
      h.runner.extend_scope(
        ids=["c"],
        expected_revision=h.backend.state().unwrap().revision,
      )
      is Err(_),
    )
    assert_true(h.runner.begin_planning() is Err(_))
    h.shared.release("attempt-a-1")
    parallel_yield_until(what="one running", check=() => h.shared.active == 1)
    assert_false(h.runner.quiescent())
    assert_true(h.owner.status().active_bindings.all(b => active.contains(b)))
    h.shared.release("attempt-b-1")
    controlled_wait_paused(h)
    assert_true(h.runner.quiescent())
    assert_eq(h.runner.status().settled, 2)
    ignore(
      h.runner
      .extend_scope(
        ids=["c"],
        expected_revision=h.backend.state().unwrap().revision,
      )
      .unwrap(),
    )
    assert_true(h.runner.resume_workflow())
    parallel_yield_until(what="three settled", check=() => {
      h.runner.status().settled == 3
    })
    controlled_wait_paused(h)
    assert_eq(h.shared.runs, 3)
    assert_true(h.runner.resume_workflow())
    controlled_wait_paused(h)
    assert_eq(h.shared.runs, 3)
    assert_eq(h.runner.status().remaining_executions, 7)
    parallel_assert_journal(h)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "planning reservations consume original execution and elapsed budgets without becoming fake settlements" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["a"])
    ignore(
      h.runner
      .start_controlled(
        parallel_spec(
          max_executions=2,
          max_elapsed_ms=2000,
          execution_timeout_ms=1000,
        ),
      )
      .unwrap(),
    )
    ignore(h.runner.begin_planning().unwrap())
    assert_true(h.runner.planning_gate())
    assert_false(h.runner.resume_workflow())
    assert_true(
      h.runner.extend_scope(
        ids=["a"],
        expected_revision=h.backend.state().unwrap().revision,
      )
      is Err(_),
    )
    ignore(h.runner.end_planning(binding=None).unwrap())
    assert_eq(h.runner.status().remaining_executions, 1)
    assert_eq(h.runner.status().settled, 0)
    ignore(h.runner.begin_planning().unwrap())
    h.clock.now_ms = 2000L
    assert_false(h.runner.planning_gate())
    ignore(h.runner.end_planning(binding=None).unwrap())
    assert_eq(h.runner.status().remaining_executions, 0)
    assert_true(h.runner.begin_planning() is Err(_))
    h.runner.cancel()
    assert_true(
      h.runner.extend_scope(
        ids=["a"],
        expected_revision=h.backend.state().unwrap().revision,
      )
      is Err(_),
    )
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
