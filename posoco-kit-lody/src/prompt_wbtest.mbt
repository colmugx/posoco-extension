///|
test "prompt section is stable and covers delegation semantics" {
  let section = prompt_section()
  assert_true(section.contains("## Delegated tasks (lody)"))
  assert_true(section.contains("lody_"))
  assert_true(section.contains("timed_out"))
  assert_true(section.contains("task id"))
  assert_eq(prompt_section(), section)
}
