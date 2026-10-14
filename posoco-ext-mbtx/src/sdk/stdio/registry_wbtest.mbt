///|
fn test_registry(
  group : @async.TaskGroup[Unit],
  init~ : Registry = Registry::{ pending: Map([]), next_id: 1, closed: false, },
) -> @fuwaroid.Fuwaroid[RegistryCmd, RegistryQuery, RegistryReply] {
  @fuwaroid.Fuwaroid::spawn(
    group~,
    init~,
    on_cmd=registry_on_cmd,
    on_query=registry_on_query,
  )
}

///|
fn registry_outcome(content : String) -> @protocol.Outcome {
  @protocol.Success(content~, structured=None)
}

///|
async fn registry_ask_admitted(
  registry : @fuwaroid.Fuwaroid[RegistryCmd, RegistryQuery, RegistryReply],
) -> (Int32, @aqueue.Queue[@protocol.Outcome]) {
  match registry.ask(Acquire, timeout_ms=registry_timeout_ms) {
    Ok(Admitted(id, waiter)) => (id, waiter)
    _ => abort("the registry did not admit the request")
  }
}

///|
async fn registry_ask_acked(
  registry : @fuwaroid.Fuwaroid[RegistryCmd, RegistryQuery, RegistryReply],
  query : RegistryQuery,
) -> Unit {
  match registry.ask(query, timeout_ms=registry_timeout_ms) {
    Ok(Acked) => ()
    _ => abort("the registry refused a query that must be accepted")
  }
}

///|
async fn registry_expect_refused(
  registry : @fuwaroid.Fuwaroid[RegistryCmd, RegistryQuery, RegistryReply],
  query : RegistryQuery,
  reason~ : String,
) -> Unit {
  match registry.ask(query, timeout_ms=registry_timeout_ms) {
    Ok(Refused(actual)) => assert_eq(actual, reason)
    _ => fail("expected the registry to refuse the query")
  }
}

///|
async test "out-of-order replies settle their own waiter" {
  @async.with_task_group(group => {
    let registry = test_registry(group)
    let first = registry_ask_admitted(registry)
    let second = registry_ask_admitted(registry)
    // The host answers the second request first; each waiter receives the
    // outcome that belongs to its own id.
    registry_ask_acked(
      registry,
      Settle(id=second.0, outcome=registry_outcome("second")),
    )
    registry_ask_acked(
      registry,
      Settle(id=first.0, outcome=registry_outcome("first")),
    )
    assert_eq(first.1.get(), registry_outcome("first"))
    assert_eq(second.1.get(), registry_outcome("second"))
    registry_ask_acked(registry, Finish)
  })
}

///|
async test "unknown and duplicate replies are explicit refusals" {
  @async.with_task_group(group => {
    let registry = test_registry(group)
    registry_expect_refused(
      registry,
      Settle(id=42, outcome=registry_outcome("lost")),
      reason="unknown or settled reply id",
    )
    let only = registry_ask_admitted(registry)
    registry_ask_acked(
      registry,
      Settle(id=only.0, outcome=registry_outcome("once")),
    )
    registry_expect_refused(
      registry,
      Settle(id=only.0, outcome=registry_outcome("again")),
      reason="unknown or settled reply id",
    )
  })
}

///|
async test "exhausted request ids refuse admission instead of wrapping" {
  @async.with_task_group(group => {
    let registry = test_registry(
      init=Registry::{ pending: Map([]), next_id: 2147483647, closed: false, },
      group,
    )
    registry_expect_refused(registry, Acquire, reason="request id exhausted")
  })
}

///|
async test "released registrations free the registry and late replies are refused" {
  @async.with_task_group(group => {
    let registry = test_registry(group)
    let abandoned = registry_ask_admitted(registry)
    let kept = registry_ask_admitted(registry)
    match registry.tell(Release(id=abandoned.0)) {
      Ok(_) => ()
      Err(_) => fail("an open registry must accept the release")
    }
    registry_expect_refused(
      registry,
      Settle(id=abandoned.0, outcome=registry_outcome("late")),
      reason="unknown or settled reply id",
    )
    registry_ask_acked(
      registry,
      Settle(id=kept.0, outcome=registry_outcome("kept")),
    )
    assert_eq(kept.1.get(), registry_outcome("kept"))
    registry_ask_acked(registry, Finish)
  })
}

///|
async test "finish rejects a final result while requests are pending" {
  @async.with_task_group(group => {
    let registry = test_registry(group)
    let _ignored = registry_ask_admitted(registry)
    // Finish is one atomic step: it refuses and closes admission, so a
    // handler that returns with in-flight requests cannot report a result.
    registry_expect_refused(
      registry,
      Finish,
      reason="handler returned with pending requests",
    )
    registry_expect_refused(
      registry,
      Acquire,
      reason="the request registry is closed",
    )
    registry_expect_refused(
      registry,
      Settle(id=1, outcome=registry_outcome("after finish")),
      reason="the request registry is closed",
    )
  })
}

///|
async test "finish closes a drained registry to further traffic" {
  @async.with_task_group(group => {
    let registry = test_registry(group)
    let only = registry_ask_admitted(registry)
    registry_ask_acked(
      registry,
      Settle(id=only.0, outcome=registry_outcome("settled")),
    )
    registry_ask_acked(registry, Finish)
    registry_expect_refused(
      registry,
      Acquire,
      reason="the request registry is closed",
    )
    registry_expect_refused(
      registry,
      Settle(id=only.0, outcome=registry_outcome("after finish")),
      reason="the request registry is closed",
    )
  })
}

///|
async test "a stopped registry refuses asks without waiting for the deadline" {
  @async.with_task_group(group => {
    let registry = test_registry(group)
    registry.close()
    match registry.join() {
      @fuwaroid.Graceful => ()
      reason => fail("expected graceful stop, got \{Repr(reason)}")
    }
    match registry.ask(Acquire, timeout_ms=registry_timeout_ms) {
      Err(NotDelivered(MailboxClosed)) => ()
      _ => fail("stopped registry must refuse admission")
    }
  })
}

///|
test "registry ask failures map to explicit messages" {
  inspect(
    registry_ask_failure(
      "request was not registered",
      NotDelivered(MailboxClosed),
    ),
    content="request was not registered because the registry is closed",
  )
  inspect(
    registry_ask_failure("reply was not settled", NotDelivered(MailboxFull)),
    content="reply was not settled because the registry mailbox is full",
  )
  inspect(
    registry_ask_failure("pending check failed", TimedOut),
    content="pending check failed because the registry did not answer in time",
  )
  inspect(
    registry_ask_failure("reply was not settled", Stopped),
    content="reply was not settled because the registry stopped",
  )
}
