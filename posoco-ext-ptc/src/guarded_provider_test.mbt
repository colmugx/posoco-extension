///|
/// A policy that denies all leaf calls, even after another hook approved.
struct PtcDenyPolicy {}

///|
pub impl @posoco.PipelineHook for PtcDenyPolicy with fn before_tool(
  _self : PtcDenyPolicy,
  _call : @kernel.ToolCall,
) -> @posoco.ToolDecision {
  @posoco.ToolDecision::Reject(reason="plan mode veto")
}

///|
async test "PTC final veto blocks approved native write execution" {
  let tool_def : @kernel.ToolDef = {
    name: @kernel.ToolName::unchecked("edit"),
    description: "Edit source",
    input_schema: { "type": "object" },
    owner: @kernel.OwnerId::unchecked("test-ptc"),
    policy: @kernel.ExecutionPolicy::Sequential,
    provenance: None,
  }
  let actual = @posoco.RecordingToolProvider([tool_def], {
    "edit": @posoco.ScriptedToolOutcome::OutcomeOk(
      @kernel.Success(content="edited", structured=None),
    ),
  })
  let final_policy = PtcDenyPolicy::{ }
  let guarded = @posoco-ext-ptc.PtcGuardedProvider(
    inner=actual as &@posoco.ToolProvider,
    guards=[final_policy as &@posoco.PipelineHook],
  )
  let dispatcher = @posoco.ScopedToolDispatch([guarded as &@posoco.ToolProvider])
  let result = dispatcher.call("edit", { "path": "test.mbt" })
  assert_true(result is @kernel.ToolReportedError(..))
  assert_eq(actual.exec_records().length(), 0)
}
