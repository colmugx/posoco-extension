///|
test "utc timestamps render as pure utc civil time" {
  inspect(utc_timestamp(0L), content="1970-01-01 00:00:00 UTC")
  inspect(utc_timestamp(86399999L), content="1970-01-01 23:59:59 UTC")
  inspect(utc_timestamp(86400000L), content="1970-01-02 00:00:00 UTC")
  // Leap day in a divisible-by-400 year and in a divisible-by-4 year.
  inspect(utc_timestamp(951782400000L), content="2000-02-29 00:00:00 UTC")
  inspect(utc_timestamp(1709164800000L), content="2024-02-29 00:00:00 UTC")
  inspect(utc_timestamp(1700000000000L), content="2023-11-14 22:13:20 UTC")
  // Before the epoch the floor division must not round the wrong way.
  inspect(utc_timestamp(-1L), content="1969-12-31 23:59:59 UTC")
  inspect(utc_timestamp(-86400001L), content="1969-12-30 23:59:59 UTC")
}

///|
test "inspector labels are stable human text" {
  assert_eq(attempt_kind_label(@client.Discuss), "Discuss")
  assert_eq(attempt_kind_label(@client.Execute), "Execute")
  assert_eq(attempt_kind_label(@client.Review), "Review")
  assert_eq(attempt_status_label(@client.Queued), "Queued")
  assert_eq(attempt_status_label(@client.Running), "Running")
  assert_eq(attempt_status_label(@client.Succeeded), "Succeeded")
  assert_eq(attempt_status_label(@client.Failed), "Failed")
  assert_eq(attempt_status_label(@client.Cancelled), "Cancelled")
  assert_eq(attempt_status_label(@client.Interrupted), "Interrupted")
  assert_eq(review_label(@client.Pending), "Review pending")
  assert_eq(review_label(@client.Approved), "Review approved")
  assert_eq(review_label(@client.ChangesRequested), "Review changes requested")
  // Dependencies always show the id alongside the title.
  assert_eq(
    dependency_entry_label("Design review", "task-1"),
    "Design review (task-1)",
  )
  assert_eq(
    dependency_entry_label("Unavailable task", "task-x"),
    "Unavailable task (task-x)",
  )
}

///|
fn wbtest_attempt_model(
  created_ms : Double,
  started_json : Json,
  finished_json : Json,
) -> Model {
  let task : Json = {
    "id": "t",
    "title": "Title t",
    "description": "Task details",
    "stage": "ready",
    "priority": "high",
    "definition_of_done": [],
    "dependencies": [],
    "created_at_ms": 10,
    "updated_at_ms": 20,
    "ready_since_ms": null,
  }
  let attempt : Json = {
    "id": "attempt-1",
    "task_id": "t",
    "kind": "execute",
    "status": "succeeded",
    "review": null,
    "created_at_ms": created_ms,
    "started_at_ms": started_json,
    "finished_at_ms": finished_json,
    "updated_at_ms": created_ms + 60000,
  }
  let frame = @protocol.encode_server_frame(
    Snapshot({
      protocol_version: 1,
      last_seq: 0L,
      board_revision: 1L,
      payload: {
        "board": { "revision": 1, "tasks": [task], "attempts": [attempt] },
        "events": [],
      },
    }),
  )
  let replica = @client.BoardReplica::empty()
  guard replica.apply_text(frame) is Applied else {
    abort("Invalid attempt test snapshot")
  }
  {
    ..Model::empty(true),
    replica,
    connection: Online,
    selected_task: Some("t"),
  }
}

///|
test "attempt timestamps render only what the record carries" {
  let attempts = inspector_attempts(
    wbtest_attempt_model(1700000000000.0, null, null),
  )
  assert_eq(attempts.length(), 1)
  inspect(
    attempt_times(attempts[0]),
    content="created 2023-11-14 22:13:20 UTC · updated 2023-11-14 22:14:20 UTC",
  )
  let with_start = inspector_attempts(
    wbtest_attempt_model(1700000000000.0, 1700000010000, null),
  )
  inspect(
    attempt_times(with_start[0]),
    content="created 2023-11-14 22:13:20 UTC · started 2023-11-14 22:13:30 UTC · updated 2023-11-14 22:14:20 UTC",
  )
  let with_finish = inspector_attempts(
    wbtest_attempt_model(1700000000000.0, 1700000010000, 1700000050000),
  )
  inspect(
    attempt_times(with_finish[0]),
    content="created 2023-11-14 22:13:20 UTC · started 2023-11-14 22:13:30 UTC · finished 2023-11-14 22:14:10 UTC · updated 2023-11-14 22:14:20 UTC",
  )
}
