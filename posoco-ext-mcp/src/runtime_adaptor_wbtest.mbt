///|
/// Whitebox tests for the runtime-seam pieces (McpRuntime).

///|
/// Records execute_tool calls; model/cancel/compact are out of scope here.
struct RecordingRuntime {
  executed : Array[String]
}

///|
pub impl @runtime.Runtime for RecordingRuntime with fn call_model(
  self,
  scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tool_definitions : Array[@kernel.ToolDef],
  _call_options : Json,
  _on_chunk : ((@posoco.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  ignore(self)
  ignore(scope)
  Err(@kernel.Transport(reason="not under test"))
}

///|
pub extend RecordingRuntime with @colmugx/posoco/runtime.Runtime::{
  cancel_effects,
  execute_tool,
  call_model,
  compact,
}

///|
pub impl @runtime.Runtime for RecordingRuntime with fn execute_tool(
  self,
  context : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  self.executed.push(context.tool_name.to_string())
  @kernel.Success(content="fallback", structured=None)
}

///|
pub impl @runtime.Runtime for RecordingRuntime with fn cancel_effects(
  self,
  run_id~ : @kernel.RunId,
  effect_ids : Array[@kernel.EffectId],
  _reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  ignore(self)
  ignore(run_id)
  effect_ids.map(id => (id, @kernel.NotPropagated))
}

///|
pub impl @runtime.Runtime for RecordingRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  ignore(self)
  ignore(scope)
  Err(@kernel.Transport(reason="not under test"))
}

///|
fn effect_for(name : String) -> @runtime.EffectContext {
  // A minimal fixed binding: the provider is a no-op recorder; the context
  // factory builds an unbound ToolCallContext (no child pipeline needed).
  let provider = NoopBoundProvider::{ }
  @runtime.EffectContext::EffectContext(
    run_id=@kernel.RunId::unchecked("run_test"),
    effect_id=@kernel.EffectId::{ value: 1, },
    owner=@kernel.OwnerId::unchecked("posoco_ext_mcp"),
    call_id=@kernel.CallId::unchecked("call_1"),
    tool_name=@kernel.ToolName::unchecked(name),
    arguments=Json::null(),
    bound_tool=provider as &@posoco.ToolProvider,
    tool_context=fn(register_cancel : (&@posoco.ToolCancellable) -> Unit) {
      @posoco.ToolCallContext(
        effect_id=@kernel.EffectId::{ value: 1, },
        call_id=@kernel.CallId::unchecked("call_1"),
        name=@kernel.ToolName::unchecked(name),
        arguments=Json::null(),
        register_cancel~,
      )
    },
  )
}

///|
struct NoopBoundProvider {}

///|
impl @posoco.ToolProvider for NoopBoundProvider with fn list_tools(
  _self : NoopBoundProvider,
) -> Array[@kernel.ToolDef] {
  []
}

///|
impl @posoco.ToolProvider for NoopBoundProvider with fn execute(
  _self : NoopBoundProvider,
  _ctx : @posoco.ToolCallContext,
) -> @kernel.ToolOutcome {
  @kernel.Success(content="noop", structured=None)
}

///|
async test "mcp_runtime_delegates_unknown_names_to_fallback" {
  let fallback = RecordingRuntime::{ executed: [], }
  let bridge = MCPToolBridge()
  let runtime = McpRuntime(bridge~, fallback=fallback as &@runtime.Runtime)
  let outcome = runtime.execute_tool(effect_for("read"))
  assert_true(outcome is @kernel.Success(_))
  assert_eq(fallback.executed.length(), 1)
  assert_eq(fallback.executed[0], "read")
}

///|
test "mcp_runtime_routing_decision_follows_live_map" {
  let fallback = RecordingRuntime::{ executed: [], }
  let bridge = MCPToolBridge()
  let runtime = McpRuntime(bridge~, fallback=fallback as &@runtime.Runtime)
  assert_false(runtime.handles("srv__tool"))
  bridge.tool_to_conn["srv__tool"] = 0
  assert_true(runtime.handles("srv__tool"))
}

///|
/// Marker error that fails the harness task group below.
suberror HarnessTrigger

///|
/// Ambient-cancellation harness for `execute_tool`: a spawned child fails
/// the task group, which cancels the group body (the current task). The
/// Cancelled raised at the body's suspension point is swallowed; the
/// cancelled state is sticky, so everything after the catch runs with
/// `@async.is_being_cancelled() == true`.
///
/// Known limitation: the MCP-handled branch of `McpRuntime::execute_tool`
/// cannot reach a deterministic provider raise in this suite — the mcp SDK
/// has no injectable transport (`AnyTransport` is a closed enum, `MCPClient`
/// has no public constructor), so a bridge raise requires a live server.
/// This test pins the constructible half of the contract: the delegation
/// path stays transparent while ambient-cancelled. The live-fixture e2e suite
/// covers the handled-branch re-raise identity.
async test "mcp_runtime_execute_tool_delegates_under_ambient_cancellation" {
  let fallback = RecordingRuntime::{ executed: [], }
  let bridge = MCPToolBridge()
  let runtime = McpRuntime(bridge~, fallback=fallback as &@runtime.Runtime)
  let outcome : Ref[@kernel.ToolOutcome?] = Ref(None)
  let cancelled_before_delegation = Ref(false)
  let triggered = try {
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true) <| () => { raise HarnessTrigger }
      // Suspension gate: the group's cancellation interrupts this sleep.
      // Async 0.22.3: cancellation is uncatchable, so absorb it with
      // handle_cancellation and observe the ambient cancellation by
      // continuing on the None path.
      if @async.handle_cancellation(() => @async.sleep(5_000)) is None {
        cancelled_before_delegation.val = true
        outcome.val = Some(runtime.execute_tool(effect_for("read")))
      }
    })
    false
  } catch {
    HarnessTrigger => true
    _ => false
  }
  assert_true(triggered)
  assert_true(cancelled_before_delegation.val)
  assert_eq(fallback.executed.length(), 1)
  assert_eq(fallback.executed[0], "read")
  assert_true(outcome.val is Some(_))
}
