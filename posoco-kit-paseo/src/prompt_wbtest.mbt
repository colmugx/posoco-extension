///|
test "prompt section is stable and covers orchestration semantics" {
  let section = prompt_section()
  assert_true(section.contains("## Delegated agents (paseo)"))
  assert_true(section.contains("create_agent"))
  assert_true(section.contains("send_agent_prompt"))
  assert_true(section.contains("get_agent_status"))
  assert_true(section.contains("agent id"))
  assert_true(section.contains("kill_agent"))
  assert_eq(prompt_section(), section)
}
