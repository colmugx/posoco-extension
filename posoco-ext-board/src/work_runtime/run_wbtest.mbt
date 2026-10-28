///|
test "run activity log keeps only the recent lines" {
  let store = WorkRunStore::WorkRunStore()
  let run = store.add("task-1", work_session_id("task-1", "rd"), "work", "rd")
  for index in 0..<25 {
    run.activity("step", "line \{index}")
  }
  assert_eq(run.activities.length(), 20)
  assert_eq(run.activities[0].text, "line 5")
  assert_eq(run.activities[19].text, "line 24")
}

///|
test "append_tail keeps the bounded tail" {
  assert_eq(append_tail("", "abcdef", 4), "cdef")
  assert_eq(append_tail("abc", "de", 10), "abcde")
  assert_eq(append_tail("abc", "def", 0), "")
}

///|
test "one_line_preview collapses whitespace and caps length" {
  assert_eq(one_line_preview("  a \n\t b  c ", 10), "a b c")
  let long = one_line_preview("x1x2x3x4x5x6x7x8x9", 6)
  assert_eq(long, "x1x2x3")
}

///|
test "run projection keeps the wire keys" {
  let store = WorkRunStore::WorkRunStore()
  let run = store.add("task-2", work_session_id("task-2", "te"), "work", "te")
  run.status = "failed"
  run.error = Some("boom")
  run.result = Some("partial")
  run.activity("start", "Started as te")
  let json = match run.to_json() {
    Object(fields) => fields
    _ => fail("run projection must be an object")
  }
  assert_eq(json.get("task_id"), Some(Json::string("task-2")))
  assert_eq(
    json.get("session_id"),
    Some(Json::string(work_session_id("task-2", "te"))),
  )
  assert_eq(json.get("status"), Some(Json::string("failed")))
  assert_eq(json.get("error"), Some(Json::string("boom")))
  assert_eq(json.get("result"), Some(Json::string("partial")))
  assert_eq(json.get("role"), Some(Json::string("te")))
  assert_eq(json.get("phase"), Some(Json::string("work")))
  match json.get("steps") {
    Some(Number(0.0, ..)) => ()
    _ => fail("a fresh run has zero steps")
  }
  assert_eq(json.get("preview"), Some(Json::string("")))
  assert_eq(json.get("reasoning"), Some(Json::string("")))
  match json.get("activities") {
    Some(Array(items)) => assert_eq(items.length(), 1)
    _ => fail("run projection must carry activities")
  }
}
