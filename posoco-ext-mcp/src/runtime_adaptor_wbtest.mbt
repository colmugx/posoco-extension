///|
/// Whitebox tests for the runtime-seam pieces (McpRuntime, McpCatalogSource).

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
  effect_ids : Array[@kernel.EffectId],
  _reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, @kernel.NotPropagated))
}

///|
pub impl @runtime.Runtime for RecordingRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  ignore(self)
  ignore(scope)
  Err(@kernel.Transport(reason="not under test"))
}

///|
fn effect_for(name : String) -> @runtime.EffectContext {
  {
    effect_id: @kernel.EffectId::{ value: 1, },
    owner: @kernel.OwnerId::unchecked("posoco_ext_mcp"),
    call_id: @kernel.CallId::unchecked("call_1"),
    tool_name: @kernel.ToolName::unchecked(name),
    arguments: Json::null(),
  }
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
test "mcp_catalog_source_combines_base_and_bridge_tools" {
  let bridge = MCPToolBridge()
  let base_tool : @kernel.ToolDef = {
    name: @kernel.ToolName::unchecked("read"),
    description: "base",
    input_schema: Json::object(Map::from_array([])),
    owner: @kernel.OwnerId::unchecked("posoco_ext_read"),
    policy: @kernel.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_read"),
  }
  let source = McpCatalogSource(bridge~, base_tools=[base_tool])
  assert_eq(source.revision(), 0)
  let tools = source.tools()
  assert_eq(tools.length(), 1) // bridge not activated: no MCP tools yet
  assert_eq(tools[0].name.to_string(), "read")
}

///|
async test "mcp_catalog_source_revision_advances_on_activation" {
  let bridge = MCPToolBridge()
  let source = McpCatalogSource(bridge~)
  let _ = bridge.activate() // empty pending: bump, no failures
  assert_eq(source.revision(), 1)
  assert_true(source.tools().is_empty())
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
/// This test pins the constructible half of the contract (the delegation
/// path stays transparent while ambient-cancelled); Wave 2 e2e with
/// test_fixtures servers asserts the handled-branch re-raise identity.
async test "mcp_runtime_execute_tool_delegates_under_ambient_cancellation" {
  let fallback = RecordingRuntime::{ executed: [], }
  let bridge = MCPToolBridge()
  let runtime = McpRuntime(bridge~, fallback=fallback as &@runtime.Runtime)
  let outcome : Ref[@kernel.ToolOutcome?] = Ref(None)
  let cancelled_before : Ref[Bool] = Ref(false)
  let cancelled_after : Ref[Bool] = Ref(false)
  let triggered = try {
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true) <| () => { raise HarnessTrigger }
      // Suspension gate: only the group's cancellation wakes this early.
      @async.sleep(5_000) catch {
        _ => ()
      }
      cancelled_before.val = @async.is_being_cancelled()
      outcome.val = Some(runtime.execute_tool(effect_for("read")))
      cancelled_after.val = @async.is_being_cancelled()
    })
    false
  } catch {
    HarnessTrigger => true
    _ => false
  }
  assert_true(triggered)
  assert_true(cancelled_before.val)
  assert_true(cancelled_after.val)
  assert_eq(fallback.executed.length(), 1)
  assert_eq(fallback.executed[0], "read")
  assert_true(outcome.val is Some(_))
}
