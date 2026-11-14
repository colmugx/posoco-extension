///|
async test "pause and stop during protected reservation do not cancel already reserved work" {
  for pause in [true, false] {
    @async.with_task_group(group => {
      let journal : HoldingWorkflowJournal = {
        entered: @aqueue.Queue(kind=Unbounded),
        release: @aqueue.Queue(kind=Unbounded),
        writes: 0,
      }
      let h = workflow_harness(group, tasks=["alpha"], store=journal)
      assert_true(h.runner.start(workflow_spec()) is Ok(_))
      journal.entered.get()
      assert_true(h.owner.status().admission_busy)
      assert_eq(h.runner.status().admitted, 0)
      if pause {
        assert_true(h.runner.pause())
      } else {
        assert_true(h.runner.stop_after_current())
      }
      journal.release.put(())
      if pause {
        workflow_wait_phase(h, @workflow.Paused)
        assert_eq(h.runner.status().succeeded, 1)
        assert_true(h.runner.stop_after_current())
      }
      let status = h.runner.wait()
      assert_eq(status.phase, @workflow.Stopped)
      assert_eq(status.succeeded, 1)
      assert_eq(h.adapter.runs, 1)
      assert_eq(h.owner.bindings()[0].phase, @execution.Settled)
      assert_true(h.runner.shutdown())
      h.backend.shutdown()
    })
  }
}
