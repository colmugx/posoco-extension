///|
test "progress records trimmed messages and drops blanks" {
  let log = WorkProgressLog::WorkProgressLog()
  log.record("task-1", "attention", "  needs a decision  ")
  log.record("task-1", "step", "   ")
  assert_eq(log.all().length(), 1)
  assert_eq(log.all()[0].message, "needs a decision")
  assert_eq(log.all()[0].kind, "attention")
  assert_eq(log.all()[0].task_id, "task-1")
}

///|
test "progress log stays bounded per ticket" {
  let log = WorkProgressLog::WorkProgressLog()
  for index in 0..<60 {
    log.record("task-1", "step", "update \{index}")
  }
  let updates = log.all()
  assert_eq(updates.length(), 50)
  assert_eq(updates[0].message, "update 10")
  assert_eq(updates[49].message, "update 59")
}

///|
test "progress dismiss clears one ticket or everything" {
  let log = WorkProgressLog::WorkProgressLog()
  log.record("task-1", "step", "one")
  log.record("task-2", "step", "two")
  log.dismiss(Some("task-1"))
  assert_eq(log.all().length(), 1)
  assert_eq(log.all()[0].task_id, "task-2")
  log.record("task-1", "step", "three")
  log.dismiss(None)
  assert_eq(log.all().length(), 0)
}

///|
test "attention counts distinct tickets with attention or blocked updates" {
  let log = WorkProgressLog::WorkProgressLog()
  assert_eq(log.attention_tasks(), 0)
  log.record("task-1", "step", "fine")
  log.record("task-1", "attention", "stuck on a decision")
  log.record("task-1", "blocked", "still stuck")
  log.record("task-2", "attention", "needs input")
  log.record("task-3", "step", "fine")
  assert_eq(log.attention_tasks(), 2)
  let projection = log.all()[0].to_json().stringify()
  assert_true(projection.contains("\"task_id\":\"task-1\""))
  assert_true(projection.contains("\"kind\":\"step\""))
  assert_true(projection.contains("\"message\":\"fine\""))
  assert_true(projection.contains("\"at_ms\":"))
}
