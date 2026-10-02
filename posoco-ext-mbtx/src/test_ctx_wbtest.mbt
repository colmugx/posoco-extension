///|
/// Adapt a legacy ToolCall to the 0.21 ToolCallContext shape.
fn test_ctx(call : @posoco.ToolCall) -> @posoco.ToolCallContext {
  {
    effect_id: @kernel.EffectId::{ value: 1, },
    call_id: call.call_id,
    name: call.name,
    arguments: call.arguments,
    register_cancel: fn(_ : &@posoco.ToolCancellable) { () },
  }
}
