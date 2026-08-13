///|
test "work_state/snapshot_is_detached" {
  let state = HandoffWorkState::new()
  state.set_objective("Implement handoff")
  state.add_done_when("HANDOFF.md is written")
  let first = state.snapshot()
  first.done_when.push("mutated outside state")
  let second = state.snapshot()
  assert_eq(second.objective, Some("Implement handoff"))
  assert_eq(second.done_when, ["HANDOFF.md is written"])
}

///|
test "work_state/complete_moves_item_out_of_queue" {
  let state = HandoffWorkState::new()
  state.enqueue("write renderer")
  state.enqueue("run tests")
  state.complete("write renderer")
  let work = state.snapshot()
  assert_eq(work.completed, ["write renderer"])
  assert_eq(work.queue, ["run tests"])
}

///|
test "work_state/resolve_blocker_removes_active_blocker" {
  let state = HandoffWorkState::new()
  state.add_blocker("Posoco API mismatch")
  state.add_blocker("moon unavailable")
  state.resolve_blocker("Posoco API mismatch")
  assert_eq(state.snapshot().blockers, ["moon unavailable"])
}

///|
test "work_state/validation_check_has_one_status" {
  let state = HandoffWorkState::new()
  state.validation_not_run("moon test")
  state.validation_failed("moon test")
  let failed = state.snapshot()
  assert_eq(failed.validation_not_run, [])
  assert_eq(failed.validation_failed, ["moon test"])
  assert_eq(failed.validation_passed, [])

  state.validation_passed("moon test")
  let passed = state.snapshot()
  assert_eq(passed.validation_not_run, [])
  assert_eq(passed.validation_failed, [])
  assert_eq(passed.validation_passed, ["moon test"])
}

///|
test "work_state/empty_string_clears_singular_field" {
  let state = HandoffWorkState::new()
  state.set_current_work("Implement renderer")
  state.set_next_action("Run tests")
  state.set_current_work("")
  state.set_next_action("")
  let work = state.snapshot()
  assert_eq(work.current_work, None)
  assert_eq(work.next_action, None)
}
