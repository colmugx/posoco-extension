// vocabulary_wbtest.mbt — the Phase 3 tool list is exactly the eight names,
// and detection is exact table membership (no prefix rule).

///|
test "the vocabulary is the eight Phase 3 tool names" {
  inspect(
    paseo_tool_names().join(","),
    content="create_agent,send_agent_prompt,get_agent_status,list_agents,cancel_agent,archive_agent,kill_agent,update_agent",
  )
  inspect(PASEO_TOOL_CREATE_AGENT, content="create_agent")
  inspect(PASEO_TOOL_SEND_AGENT_PROMPT, content="send_agent_prompt")
  inspect(PASEO_TOOL_GET_AGENT_STATUS, content="get_agent_status")
  inspect(PASEO_TOOL_LIST_AGENTS, content="list_agents")
  inspect(PASEO_TOOL_CANCEL_AGENT, content="cancel_agent")
  inspect(PASEO_TOOL_ARCHIVE_AGENT, content="archive_agent")
  inspect(PASEO_TOOL_KILL_AGENT, content="kill_agent")
  inspect(PASEO_TOOL_UPDATE_AGENT, content="update_agent")
}

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

///|
test "the proposed server name is the lowercase host name" {
  inspect(PASEO_MCP_SERVER_NAME, content="paseo")
}
