///|
test "workflow composition verifies the exact authoritative backend identity" {
  let backend = @backend.BoardBackend()
  let owner = @execution.BoardExecutionOwner(
    backend~,
    adapter=@execution.PosocoBoardExecutionAdapter(extensions=() => []),
    store=@execution.MemoryBoardExecutionStore(),
  )
  assert_true(owner.uses_backend(backend))
  assert_false(owner.uses_backend(@backend.BoardBackend()))
}
