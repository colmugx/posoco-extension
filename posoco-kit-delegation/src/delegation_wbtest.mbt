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
