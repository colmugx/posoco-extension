///|
/// Pure mapping tests for the kernel-backed invoker: a synthetic
/// ToolCallContext carries a fake invoke closure, so every kernel outcome
/// spelling is checked without a compiler spawn or a kernel turn.
#warnings("-unused_async")
fn fake_kernel_ctx(
  result : @kernel.InvocationResult,
) -> @posoco.ToolCallContext {
  @posoco.ToolCallContext(
    effect_id=@kernel.EffectId::first(),
    call_id=@kernel.CallId::unchecked("call_map"),
    name=@kernel.ToolName::unchecked("run_code"),
    arguments=Json::null(),
    register_cancel=fn(_ : &@posoco.ToolCancellable) { () },
    invoke=async fn(_name : String, _args : Json) -> @kernel.InvocationResult {
      result
    },
  )
}

///|
async test "kernel invoker maps kernel outcomes to ears protocol" {
  let ok = @posoco-ext-bunraku.KernelScopedInvoker(
    ctx=fake_kernel_ctx(
      @kernel.InvocationResult::Completed(
        @kernel.ToolOutcome::Success(
          content="ok",
          structured=Some({ "read": true }),
        ),
      ),
    ),
  )
  guard ok.invoke("read", Json::null())
    is @protocol.Success(content="ok", structured=Some({ "read": true, .. })) else {
    fail("success did not map")
  }
  let denied = @posoco-ext-bunraku.KernelScopedInvoker(
    ctx=fake_kernel_ctx(
      @kernel.InvocationResult::Completed(
        @kernel.ToolOutcome::NotExecuted(
          reason=@kernel.NotExecutedReason::OwnerNotAllowed,
          original_call_id=@kernel.CallId::unchecked("c"),
        ),
      ),
    ),
  )
  guard denied.invoke("write", Json::null())
    is @protocol.Failure(code="NotExecuted", content~, ..) else {
    fail("not-executed did not map to failure")
  }
  assert_true(content.contains("OwnerNotAllowed"))
  let interrupted = @posoco-ext-bunraku.KernelScopedInvoker(
    ctx=fake_kernel_ctx(
      @kernel.InvocationResult::Interrupted(
        reason="parent settled",
        cancellation=@kernel.CancelDisposition::AlreadySettled,
        side_effects_possible=false,
      ),
    ),
  )
  guard interrupted.invoke("read", Json::null())
    is @protocol.Failure(code="Interrupted", ..) else {
    fail("interrupted did not map")
  }
}
