///|
test "session ids stay stable across roles and shaping" {
  assert_eq(work_session_id("task-1", "rd"), "rd")
  assert_eq(work_session_id("task-1", "set"), "set")
  assert_eq(work_session_id("task-1", "te"), "te")
}
