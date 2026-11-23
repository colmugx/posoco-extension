///|
async test "due loop runs once and uses fixed delay after completion" {
  let now = Ref(1000L)
  let calls = Ref(0)
  @async.with_task_group(async fn(group) {
    let runtime = LoopRuntime::start(
      group~,
      now_ms=fn() { now.val },
      sleep_ms=async fn(_ : Int32) { @async.sleep(60000) },
      execute=async fn(session_id : String, prompt : String) -> DispatchResult {
        assert_eq(session_id, "s1")
        assert_eq(prompt, "check CI")
        calls.val = calls.val + 1
        Done
      },
      trace=fn(_ : String) { () },
      max_failures=3,
      bound_session=Some("s1"),
    )
    let id = runtime.change(
      Add(session_id="s1", interval_ms=5000L, prompt="check CI"),
    ).unwrap()
    now.val = 5999L
    runtime.poll()
    assert_eq(calls.val, 0)
    now.val = 6000L
    runtime.poll()
    @async.with_timeout(2000, () => {
      while runtime.jobs()[0].run_count < 1 {
        @async.sleep(1)
      }
    })
    assert_eq(calls.val, 1)
    let first = runtime.jobs()[0]
    assert_eq(first.id, id)
    assert_eq(first.status, "scheduled")
    assert_eq(first.next_due_at_ms, 11000L)
    // The same clock instant cannot trigger an additional run.
    runtime.poll()
    assert_eq(calls.val, 1)
    runtime.shutdown()
  })
}

///|
async test "pause resume stop invalidate schedule without lost ticks" {
  let now = Ref(0L)
  let calls = Ref(0)
  @async.with_task_group(async fn(group) {
    let runtime = LoopRuntime::start(
      group~,
      now_ms=fn() { now.val },
      sleep_ms=async fn(_ : Int32) { @async.sleep(60000) },
      execute=async fn(_ : String, _ : String) -> DispatchResult {
        calls.val = calls.val + 1
        Done
      },
      trace=fn(_ : String) { () },
      max_failures=3,
      bound_session=Some("s1"),
    )
    let id = runtime.change(Add("s1", 1000L, "task")).unwrap()
    assert_true(runtime.change(Pause(id~)) is Ok(_))
    now.val = 2000L
    runtime.poll()
    assert_eq(calls.val, 0)
    assert_true(runtime.change(Resume(id~)) is Ok(_))
    let job = runtime.jobs()[0]
    assert_eq(job.next_due_at_ms, 3000L)
    assert_true(runtime.change(Stop(id~)) is Ok(_))
    now.val = 4000L
    runtime.poll()
    assert_eq(calls.val, 0)
    assert_eq(runtime.jobs()[0].status, "stopped")
    runtime.shutdown()
  })
}

///|
async test "inactive sessions are dormant and never receive other session work" {
  let now = Ref(0L)
  let calls = Ref(0)
  @async.with_task_group(async fn(group) {
    let runtime = LoopRuntime::start(
      group~,
      now_ms=fn() { now.val },
      sleep_ms=async fn(_ : Int32) { @async.sleep(60000) },
      execute=async fn(_ : String, _ : String) -> DispatchResult {
        calls.val = calls.val + 1
        Done
      },
      trace=fn(_ : String) { () },
      max_failures=3,
      bound_session=Some("s1"),
    )
    ignore(runtime.change(Add("s1", 1000L, "task")).unwrap())
    runtime.bind(Some("s2"))
    now.val = 2000L
    runtime.poll()
    assert_eq(calls.val, 0)
    runtime.bind(Some("s1"))
    runtime.poll()
    @async.with_timeout(2000, () => {
      while runtime.jobs()[0].run_count < 1 {
        @async.sleep(1)
      }
    })
    assert_eq(calls.val, 1)
    runtime.shutdown()
  })
}

///|
async test "Busy is retried without consuming failure budget" {
  let now = Ref(0L)
  let calls = Ref(0)
  @async.with_task_group(async fn(group) {
    let runtime = LoopRuntime::start(
      group~,
      now_ms=fn() { now.val },
      sleep_ms=async fn(_ : Int32) { @async.sleep(60000) },
      execute=async fn(_ : String, _ : String) -> DispatchResult {
        calls.val = calls.val + 1
        if calls.val == 1 { Busy } else { Done }
      },
      trace=fn(_ : String) { () },
      max_failures=3,
      bound_session=Some("s1"),
    )
    ignore(runtime.change(Add("s1", 1000L, "task")).unwrap())
    now.val = 1000L
    runtime.poll()
    @async.with_timeout(2000, () => {
      while runtime.jobs()[0].next_due_at_ms != 1500L {
        @async.sleep(1)
      }
    })
    let retriable = runtime.jobs()[0]
    assert_eq(retriable.run_count, 0)
    assert_eq(retriable.failure_count, 0)
    now.val = 1500L
    runtime.poll()
    @async.with_timeout(2000, () => {
      while runtime.jobs()[0].run_count < 1 {
        @async.sleep(1)
      }
    })
    assert_eq(calls.val, 2)
    runtime.shutdown()
  })
}

///|
async test "repeated errors pause the loop at the configured threshold" {
  let now = Ref(0L)
  @async.with_task_group(async fn(group) {
    let runtime = LoopRuntime::start(
      group~,
      now_ms=fn() { now.val },
      sleep_ms=async fn(_ : Int32) { @async.sleep(60000) },
      execute=async fn(_ : String, _ : String) -> DispatchResult {
        Error("provider failed")
      },
      trace=fn(_ : String) { () },
      max_failures=2,
      bound_session=Some("s1"),
    )
    ignore(runtime.change(Add("s1", 1000L, "task")).unwrap())
    now.val = 1000L
    runtime.poll()
    @async.with_timeout(2000, () => {
      while runtime.jobs()[0].run_count < 1 {
        @async.sleep(1)
      }
    })
    now.val = 2000L
    runtime.poll()
    @async.with_timeout(2000, () => {
      while runtime.jobs()[0].status != "paused" {
        @async.sleep(1)
      }
    })
    let job = runtime.jobs()[0]
    assert_eq(job.failure_count, 2)
    assert_eq(job.run_count, 2)
    runtime.shutdown()
  })
}
