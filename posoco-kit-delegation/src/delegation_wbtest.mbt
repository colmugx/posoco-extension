// delegation_wbtest.mbt — the neutral intent shape and validated posoco
// tool-call materialization.

///|
test "intent carries the goal plus optional placement, model and prompt" {
  let bare : DelegationIntent = {
    task: "fix the flaky test",
    cwd: None,
    model: None,
    prompt: None,
  }
  assert_eq(bare.task, "fix the flaky test")
  assert_false(bare.cwd is Some(_))
  let placed : DelegationIntent = {
    task: "migrate the docs",
    cwd: Some("/work"),
    model: Some("sonnet"),
    prompt: Some("run the suite and fix"),
  }
  assert_eq(placed.cwd, Some("/work"))
  assert_eq(placed.model, Some("sonnet"))
  assert_eq(placed, placed)
}

///|
test "calls materialize as validated posoco tool calls" {
  let call : DelegationCall = {
    tool: "create_agent",
    arguments: @json.parse("{}"),
  }
  guard call.to_tool_call(call_id="c-1") is Ok(tc) else { fail("expected Ok") }
  inspect(tc.call_id.value, content="c-1")
  inspect(tc.name.value, content="create_agent")
  guard call.to_tool_call(call_id="") is Err(message) else {
    fail("expected Err")
  }
  inspect(message, content="invalid call id: CallId must be non-empty")
  let unnamed : DelegationCall = { tool: "", arguments: @json.parse("{}"), }
  guard unnamed.to_tool_call(call_id="c-2") is Err(message) else {
    fail("expected Err")
  }
  inspect(message, content="invalid tool name: ToolName must be non-empty")
}
