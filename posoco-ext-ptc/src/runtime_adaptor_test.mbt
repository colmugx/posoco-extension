///|
/// Read-only PTC advanced-runtime proof fixtures. These intentionally avoid
/// compiler/network dependencies and test the narrow runtime seam directly.
test "PTC catalog advertises only run_code" {
  let catalog = PtcCatalogSource()
  let defs = catalog.tools()
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].name.to_string(), "run_code")
  assert_eq(catalog.revision(), 0)
}

///|
async test "PTC nested dispatch allows read and rejects other tool names" {
  let read_def : @posoco.ToolDef = {
    name: @posoco.ToolName::unchecked("read"),
    description: "Read",
    input_schema: {
      "type": "object",
      "properties": { "path": { "type": "string" } },
      "required": ["path"],
    },
    owner: @posoco.OwnerId::unchecked("ptc-read-test"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: None,
  }
  let recording = @posoco.RecordingToolProvider([read_def], {
    "read": @posoco.ScriptedToolOutcome::OutcomeOk(
      @kernel.ToolOutcome::Success(
        content="ok",
        structured=Some({ "read": true }),
      ),
    ),
  })
  let dispatch = @posoco.ScopedToolDispatch([
    recording as &@posoco.ToolProvider,
  ])
  let invoker = PtcScopedInvoker::{ dispatch, }
  let good = invoker.invoke("read", { "path": "README.md" })
  assert_true(good is @protocol.Success(..))
  let denied = invoker.invoke("write", { "path": "README.md" })
  assert_true(denied is @protocol.Failure(..))
  let recursive = invoker.invoke("run_code", {})
  assert_true(recursive is @protocol.Failure(..))
  let bad_schema = invoker.invoke("read", { "path": 123 })
  assert_true(bad_schema is @protocol.Failure(..))
  assert_eq(recording.exec_records().length(), 1)
}
