///|
test "session ids stay stable across roles and shaping" {
  assert_eq(work_session_id("task-1", "rd"), "ticket-task-1-rd")
  assert_eq(work_session_id("task-1", "set"), "ticket-task-1-set")
  assert_eq(work_session_id("task-1", "te"), "ticket-task-1-te")
  assert_eq(shape_session_id("task-1"), "shape-task-1")
}
