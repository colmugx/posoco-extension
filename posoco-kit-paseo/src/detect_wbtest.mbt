// detect_wbtest.mbt — truth tables for both detection signals.

///|
test "server-name detection is exact" {
  assert_true(detect_from_server_names(["mcp", "paseo"]))
  assert_true(detect_from_server_names(["paseo"]))
  assert_false(detect_from_server_names([]))
  assert_false(detect_from_server_names(["Paseo"]))
  assert_false(detect_from_server_names(["paseo-mcp"]))
  assert_false(detect_from_server_names(["unrelated"]))
}

///|
test "tool-name detection recognizes vocabulary members only" {
  assert_true(detect_from_tool_names(["read_file", "kill_agent"]))
  assert_true(detect_from_tool_names(["send_agent_prompt"]))
  assert_false(detect_from_tool_names([]))
  assert_false(detect_from_tool_names(["read_file", "write_file"]))
  // unprefixed vocabulary: prefixed aliases do not count
  assert_false(detect_from_tool_names(["paseo_create_agent"]))
}
