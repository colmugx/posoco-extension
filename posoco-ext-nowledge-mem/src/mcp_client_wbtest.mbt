///|
async test "call_tool_before_configure_fails_not_sent" {
  let nmem = LazyNmemMcp::LazyNmemMcp()
  match
    nmem.call_tool(
      "memory_add",
      Json::object(Map::from_array([])),
      timeout_ms=1_000,
    ) {
    Err(NotSent(message~)) => assert_true(message.contains("not configured"))
    Err(MaybePersisted(_)) => fail("an unconfigured client never sent anything")
    Ok(_) => fail("expected the unconfigured guard")
  }
  // The probe surface reports the same honest guard.
  match nmem.probe(timeout_ms=1_000) {
    Err(message) => assert_true(message.contains("not configured"))
    Ok(_) => fail("expected the unconfigured guard")
  }
}

///|
async test "refused_connect_settles_not_sent_and_caches_no_client" {
  let nmem = LazyNmemMcp::LazyNmemMcp()
  nmem.configure(
    url="http://127.0.0.1:1/mcp",
    auth_token=None,
    name="nowledge-mem",
  )
  match
    nmem.call_tool(
      "memory_add",
      Json::object(Map::from_array([])),
      timeout_ms=5_000,
    ) {
    Err(NotSent(message~)) => {
      assert_true(message.contains("connect failed"))
      assert_true(message.contains("127.0.0.1:1"))
    }
    Err(MaybePersisted(_)) => fail("a refused dial never reached the wire")
    Ok(_) => fail("a closed loopback port cannot serve memory_add")
  }
  assert_true(nmem.client is None)
}

///|
async test "pre_cancelled_call_tool_keeps_cancellation_identity" {
  let nmem = LazyNmemMcp::LazyNmemMcp()
  nmem.configure(
    url="http://127.0.0.1:1/mcp",
    auth_token=None,
    name="nowledge-mem",
  )
  @async.with_task_group(group => {
    let task = group.spawn(
      () => {
        nmem.call_tool(
          "memory_add",
          Json::object(Map::from_array([])),
          timeout_ms=60_000,
        )
      },
      allow_failure=true,
    )
    // Cancel before the child's first step: the cancellation is delivered
    // at its first await and must not be swallowed into a Result.
    task.cancel()
    try task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error =>
        fail("expected the cancellation error, got: " + error.to_string())
    } noraise {
      _ => fail("a cancelled call must not settle into data")
    }
  })
}
