// detect_wbtest.mbt — lody host detection: server names, tool prefix, and
// the canonical-identity fallback.

///|
test "lody server detection is exact" {
  inspect(lody_server_names().join(","), content="lody")
  assert_true(is_lody_server("lody"))
  assert_false(is_lody_server("Lody"))
  assert_false(is_lody_server("lody-mcp"))
  assert_false(is_lody_server(""))
}

///|
test "tool name detection covers the prefix and canonical identities" {
  assert_true(is_lody_tool_name("lody_session_create"))
  assert_true(is_lody_tool_name("lody_review_submit"))
  assert_true(is_lody_tool_name("ImageGeneration"))
  assert_true(is_lody_tool_name("ScheduleWakeup"))
  assert_false(is_lody_tool_name("session_create"))
  assert_false(is_lody_tool_name("lody"))
  assert_false(is_lody_tool_name("lodyx_tool"))
  assert_false(is_lody_tool_name("read_file"))
}

///|
test "tool call detection reads the posoco call name" {
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("c-1"),
    name: @posoco.ToolName::unchecked("lody_session_chat"),
    arguments: @json.parse("{}"),
  }
  assert_true(is_lody_tool_call(call))
  let other : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("c-2"),
    name: @posoco.ToolName::unchecked("read_file"),
    arguments: @json.parse("{}"),
  }
  assert_false(is_lody_tool_call(other))
}
