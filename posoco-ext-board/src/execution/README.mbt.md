# Trusted headless execution

This package is opt-in. Manual Attempt commands never invoke it. Hosts must
supply a fresh-extension Agent factory and explicit authorization/input policy.
Use durable journal storage for a durable Board; this example is ephemeral and
intentionally has no provider or eligible Attempt.

```mbt check
///|
async test {
  @async.with_task_group(group => {
    let backend = @backend.BoardBackend()
    backend.attach(group)
    assert_true(backend.bootstrap_snapshot() is Ok(_))
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=@execution.PosocoBoardExecutionAdapter(extensions=() => []),
      store=@execution.MemoryBoardExecutionStore(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let request : @execution.BoardExecutionRequest = {
      task_id: "task",
      attempt_id: "attempt",
      execution_id: "execution-unique",
      session_id: "session-unique",
      input: "Explicit host-authorized input",
      timeout_ms: Some(1000),
    }
    match owner.execute(request) {
      Err(error) => assert_eq(error, @execution.IneligibleAttempt)
      Ok(handle) => {
        assert_eq(handle.execution_id(), request.execution_id)
        ignore(owner.cancel(handle.execution_id()))
        ignore(handle.wait())
      }
    }
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}
```

Hosts that need bounded parallelism construct the same owner over one journal
with `BoardExecutionOwner::with_slots(max_concurrency=1..=8)` and an isolated
driver factory; slots run concurrently between the shared serialized journal
sections and keep every admission, uniqueness, cancellation and shutdown rule
above.

See `docs/S4A-execution.md` in the module for actual Posoco APIs, journal phases,
one-shot settlement, cancellation confirmation, failure windows and operator
recovery. `Unresolved` is not permission to retry; no mutation or execution is
replayed automatically. Keep ownership until shutdown confirms join.
