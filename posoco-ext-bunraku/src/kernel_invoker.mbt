///|
/// Kernel-backed nested invoker. It holds the ToolCallContext the kernel
/// wired for the enclosing run_code effect (`EffectContext.tool_context`
/// factory) and forwards every guest `ctx.call` to
/// `ToolCallContext::invoke`, so nested calls re-enter the kernel child
/// pipeline: schema validation, owner gate, hook chain (`direct=false`),
/// shared budget/depth, cancellation, and `ToolChildDeclared` attribution.

///|
/// The face the guest sees (`ToolCallContext::tools`) is computed by the
/// kernel from run_code's manifest `tool_call_owners` — non-Disabled
/// definitions owned by an allowed owner — so the declared face and the
/// invocable face are the same fact, not two lists to keep in sync.
pub struct KernelScopedInvoker {
  priv ctx : @posoco.ToolCallContext
}

///|
pub fn KernelScopedInvoker::KernelScopedInvoker(
  ctx~ : @posoco.ToolCallContext,
) -> KernelScopedInvoker {
  { ctx, }
}

///|
fn kernel_invoker_reason_text(reason : @kernel.NotExecutedReason) -> String {
  reason.to_string()
}

///|
pub impl ToolInvoker for KernelScopedInvoker with fn invoke(
  self : KernelScopedInvoker,
  name : String,
  arguments : Json,
) -> @protocol.Outcome {
  let result = self.ctx.invoke(name, arguments) catch {
    error =>
      return @protocol.Failure(
        code="InvocationFailed",
        content=error.to_string(),
        structured=None,
      )
  }
  match result {
    @kernel.InvocationResult::Completed(@kernel.Success(content~, structured~)) =>
      @protocol.Success(content~, structured~)
    // Protocol 1 of ears has no attachment frame. Do not claim success
    // while silently discarding images: report the unsupported transport.
    @kernel.InvocationResult::Completed(@kernel.SuccessWithAttachments(..)) =>
      @protocol.Failure(
        code="AttachmentTransportUnsupported",
        content="Nested ctx.call returned attachments that ears protocol 1 cannot carry; use a model-visible native tool or change the workflow.",
        structured=None,
      )
    @kernel.InvocationResult::Completed(
      @kernel.ToolReportedError(content~, structured~)
    ) => @protocol.Failure(code="ToolRejected", content~, structured~)
    @kernel.InvocationResult::Completed(
      @kernel.RuntimeFailure(error_category~, message~)
    ) =>
      @protocol.Failure(code=error_category, content=message, structured=None)
    @kernel.InvocationResult::Completed(@kernel.NotExecuted(reason~, ..)) =>
      @protocol.Failure(
        code="NotExecuted",
        content=kernel_invoker_reason_text(reason),
        structured=None,
      )
    @kernel.InvocationResult::Interrupted(
      reason~,
      cancellation~,
      side_effects_possible~
    ) =>
      @protocol.Failure(
        code="Interrupted",
        content=reason +
          " (cancellation=" +
          cancellation.to_string() +
          ", side_effects_possible=" +
          side_effects_possible.to_string() +
          ")",
        structured=None,
      )
  }
}

///|
pub extend KernelScopedInvoker with ToolInvoker::{invoke}
