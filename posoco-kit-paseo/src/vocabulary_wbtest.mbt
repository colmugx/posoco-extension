///|
test "tool name detection is exact table membership" {
  assert_true(is_paseo_tool_name("create_agent"))
  assert_true(is_paseo_tool_name("kill_agent"))
  // no prefix rule: a paseo_-prefixed alias is not a vocabulary member
  assert_false(is_paseo_tool_name("paseo_create_agent"))
  assert_false(is_paseo_tool_name("create_agentx"))
  assert_false(is_paseo_tool_name("List_Agents"))
  assert_false(is_paseo_tool_name("read_file"))
  assert_false(is_paseo_tool_name(""))
}
