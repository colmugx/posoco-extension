///|
test "run_for prefers a live role and otherwise the most recent" {
  let store = WorkRunStore::WorkRunStore()
  assert_true(store.run_for("task-1") is None)
  let rd = store.add("task-1", work_session_id("task-1", "rd"), "work", "rd")
  let set = store.add("task-1", work_session_id("task-1", "set"), "work", "set")
  rd.status = "completed"
  assert_true(store.run_for("task-1") is Some(run) && run.role == "set")
  set.status = "failed"
  assert_true(store.run_for("task-1") is Some(run) && run.role == "set")
  rd.status = "running"
  assert_true(store.run_for("task-1") is Some(run) && run.role == "rd")
}

///|
test "run_role returns the last run of a role" {
  let store = WorkRunStore::WorkRunStore()
  assert_true(store.run_role("task-1", "rd") is None)
  let first = store.add("task-1", work_session_id("task-1", "rd"), "work", "rd")
  first.status = "failed"
  let second = store.add(
    "task-1",
    work_session_id("task-1", "rd"),
    "work",
    "rd",
  )
  match store.run_role("task-1", "rd") {
    Some(run) => assert_eq(run.status, "running")
    None => fail("the last run of the role must be found")
  }
  assert_true(second.report is None)
  assert_eq(store.all().length(), 2)
}

///|
test "park records the failure; unknown runs are silently ignored" {
  let store = WorkRunStore::WorkRunStore()
  store.park("task-1", "rd", "failed", "boom")
  assert_true(store.run_for("task-1") is None)
  let _ = store.add("task-1", work_session_id("task-1", "rd"), "work", "rd")
  store.park("task-1", "rd", "failed", "boom")
  assert_true(
    store.run_role("task-1", "rd") is Some(run) &&
    run.status == "failed" &&
    run.error == Some("boom"),
  )
  store.set_status("task-1", "te", "completed", None)
  assert_true(store.run_role("task-1", "te") is None)
}

///|
test "roles_completed and counts read the run state" {
  let store = WorkRunStore::WorkRunStore()
  assert_false(store.roles_completed("task-1", ["rd", "set"]))
  let rd = store.add("task-1", work_session_id("task-1", "rd"), "work", "rd")
  assert_false(store.roles_completed("task-1", ["rd", "set"]))
  let set = store.add("task-1", work_session_id("task-1", "set"), "work", "set")
  assert_false(store.roles_completed("task-1", ["rd", "set"]))
  rd.status = "completed"
  assert_false(store.roles_completed("task-1", ["rd", "set"]))
  set.status = "completed"
  assert_true(store.roles_completed("task-1", ["rd", "set"]))
  assert_eq(store.count_running(), 0)
  let _ = store.add("task-2", work_session_id("task-2", "rd"), "work", "rd")
  assert_eq(store.count_running(), 1)
  store.dismiss("task-2")
  assert_true(store.run_for("task-2") is None)
  assert_eq(store.count_running(), 0)
}

///|
test "run journal round-trips runs and activities" {
  let store = WorkRunStore::WorkRunStore()
  let run = store.add("task-1", "rd", "work", "rd")
  run.status = "failed"
  run.error = Some("network down")
  run.activity("error", "connection lost")
  let parsed = WorkRunStore::from_json(store.to_json())
  match parsed.run_role("task-1", "rd") {
    Some(restored) => {
      assert_eq(restored.session_id, "rd")
      assert_eq(restored.status, "failed")
      assert_eq(restored.error, Some("network down"))
      assert_eq(restored.activities.length(), 1)
      assert_eq(restored.activities[0].text, "connection lost")
    }
    None => fail("run was not restored")
  }
}

///|
test "runs loaded after a restart become interrupted, never live" {
  let store = WorkRunStore::WorkRunStore()
  ignore(store.add("task-1", "rd", "work", "rd"))
  let restored = WorkRunStore::from_json(store.to_json())
  restored.interrupt_running("host restarted")
  let run = restored.run_role("task-1", "rd").unwrap()
  assert_eq(run.status, "interrupted")
  assert_eq(run.error, Some("host restarted"))
}
