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
