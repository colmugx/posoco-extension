///|
fn task_json(id : String, stage : String) -> Json {
  {
    "id": id.to_json(),
    "title": ("Task " + id).to_json(),
    "description": "Read-only task",
    "stage": stage.to_json(),
    "priority": "normal",
    "definition_of_done": [],
    "dependencies": [],
    "created_at_ms": 1234,
    "updated_at_ms": 1234,
    "ready_since_ms": null,
  }
}

///|
fn attempt_json(
  id : String,
  task_id : String,
  status : String,
  at_ms : Int,
) -> Json {
  {
    "id": id.to_json(),
    "task_id": task_id.to_json(),
    "kind": "execute",
    "status": status.to_json(),
    "review": null,
    "created_at_ms": 1234,
    "started_at_ms": 1234,
    "finished_at_ms": null,
    "updated_at_ms": at_ms.to_json(),
  }
}

///|
test "seven lanes labels grouping counts and empty state" {
  let replica = @client.BoardReplica::empty()
  assert_eq(@src.empty_message(replica), Some("Waiting for Board state"))
  assert_eq(@src.lanes().length(), 7)
  let stages = [
    "created", "refining", "ready", "running", "review", "done", "suspended",
  ]
  let tasks : Array[Json] = []
  for i, stage in stages {
    tasks.push(task_json("task-" + i.to_string(), stage))
  }
  let outcome = replica.apply_snapshot({
    protocol_version: 1,
    last_seq: 0L,
    board_revision: 1L,
    payload: {
      "board": { "revision": 1, "tasks": Json::array(tasks), "attempts": [] },
      "events": [],
    },
  })
  assert_true(outcome is @client.Applied)
  assert_eq(replica.tasks().length(), 7)
  assert_eq(@src.empty_message(replica), None)
  let labels = [
    "Created", "Refining", "Ready", "Running", "Review", "Done", "Suspended",
  ]
  for i, stage in @src.lanes() {
    assert_eq(@src.stage_label(stage), labels[i])
    assert_eq(@src.tasks_in_lane(replica, stage).length(), 1)
    assert_eq(@src.tasks_in_lane(replica, stage)[0].id, "task-" + i.to_string())
  }
}

///|
test "initial connection waits for board state and renders no cards" {
  let replica = @client.BoardReplica::empty()
  assert_false(replica.has_snapshot())
  assert_eq(@src.empty_message(replica), Some("Waiting for Board state"))
  for stage in @src.lanes() {
    assert_eq(@src.tasks_in_lane(replica, stage).length(), 0)
  }
}

///|
test "authoritative empty snapshot shows no board tasks yet" {
  let replica = @client.BoardReplica::empty()
  assert_true(
    replica.apply_snapshot({
      protocol_version: 1,
      last_seq: 0L,
      board_revision: 0L,
      payload: {
        "board": { "revision": 0, "tasks": [], "attempts": [] },
        "events": [],
      },
    })
    is @client.Applied,
  )
  assert_true(replica.has_snapshot())
  assert_eq(@src.empty_message(replica), Some("No Board tasks yet"))
}

///|
test "invalidation clears authoritative cards and waits again" {
  let replica = @client.BoardReplica::empty()
  assert_true(
    replica.apply_snapshot({
      protocol_version: 1,
      last_seq: 0L,
      board_revision: 1L,
      payload: {
        "board": {
          "revision": 1,
          "tasks": [task_json("t", "ready")],
          "attempts": [],
        },
        "events": [],
      },
    })
    is @client.Applied,
  )
  assert_eq(@src.empty_message(replica), None)
  assert_eq(@src.tasks_in_lane(replica, @client.Ready).length(), 1)
  assert_true(replica.apply_text("{") is @client.NeedsSnapshot(_))
  assert_false(replica.has_snapshot())
  assert_eq(@src.tasks_in_lane(replica, @client.Ready).length(), 0)
  assert_eq(@src.empty_message(replica), Some("Waiting for Board state"))
}

///|
test "attempt events affect card indicator and running takes precedence" {
  let replica = @client.BoardReplica::empty()
  assert_true(
    replica.apply_snapshot({
      protocol_version: 1,
      last_seq: 0L,
      board_revision: 0L,
      payload: {
        "board": {
          "revision": 0,
          "tasks": [task_json("t", "running")],
          "attempts": [],
        },
        "events": [],
      },
    })
    is @client.Applied,
  )
  assert_eq(@src.attempt_count(replica, "t"), 0)
  assert_eq(@src.attempt_indicator(replica, "t"), "No attempts")
  assert_true(
    replica.apply_event({
      seq: 1L,
      board_revision: 1L,
      kind: "board.attempt.started",
      scope: None,
      payload: {
        "attempt_id": "a",
        "task_id": "t",
        "at_ms": 1234,
        "attempt": attempt_json("a", "t", "running", 1234),
      },
    })
    is @client.Applied,
  )
  assert_eq(@src.attempt_count(replica, "t"), 1)
  assert_eq(@src.attempt_indicator(replica, "t"), "Running")
  assert_true(
    replica.apply_event({
      seq: 2L,
      board_revision: 2L,
      kind: "board.attempt.finished",
      scope: None,
      payload: {
        "attempt_id": "a",
        "task_id": "t",
        "at_ms": 1235,
        "outcome": "succeeded",
        "attempt": attempt_json("a", "t", "succeeded", 1235),
      },
    })
    is @client.Applied,
  )
  assert_eq(@src.attempt_count(replica, "t"), 1)
  assert_eq(@src.attempt_indicator(replica, "t"), "Succeeded")
  assert_true(
    replica.apply_event({
      seq: 3L,
      board_revision: 3L,
      kind: "board.attempt.started",
      scope: None,
      payload: {
        "attempt_id": "b",
        "task_id": "t",
        "at_ms": 1236,
        "attempt": attempt_json("b", "t", "running", 1236),
      },
    })
    is @client.Applied,
  )
  assert_eq(@src.attempt_count(replica, "t"), 2)
  assert_eq(@src.attempt_indicator(replica, "t"), "Running")
}

///|
test "backoff caps and connection labels never disclose protocol details" {
  assert_eq([ for i in 0..<9 => @src.retry_delay(i) ], [
    250, 500, 1000, 2000, 4000, 8000, 10000, 10000, 10000,
  ])
  assert_eq(@src.connection_label(@src.Connecting), "Connecting")
  assert_eq(@src.connection_label(@src.Online), "Online")
  assert_eq(@src.connection_label(@src.Reconnecting), "Reconnecting")
  assert_eq(@src.connection_label(@src.Offline), "Offline")
  assert_eq(
    @src.connection_label(@src.ProtocolError("sensitive detail")),
    "Protocol error",
  )
}

///|
test "move suggestions mirror the v1 stage fsm as ux only" {
  let expectations : Array[
    (@client.ClientBoardStage, Array[@client.ClientBoardStage]),
  ] = [
    (@client.Created, [@client.Refining, @client.Suspended]),
    (@client.Refining, [@client.Ready, @client.Suspended]),
    (@client.Ready, [@client.Running, @client.Refining, @client.Suspended]),
    (@client.Running, [@client.Review, @client.Suspended]),
    (
      @client.Review,
      [@client.Done, @client.Ready, @client.Refining, @client.Suspended],
    ),
    (@client.Done, [@client.Refining]),
    (@client.Suspended, [@client.Created, @client.Refining, @client.Ready]),
  ]
  for pair in expectations {
    let (stage, expected) = pair
    assert_true(@src.move_suggestions(stage) == expected)
  }
  // Every lane is covered and no lane ever suggests itself.
  for stage in @src.lanes() {
    for target in @src.move_suggestions(stage) {
      assert_false(target == stage)
    }
  }
}

///|
test "definition of done lines trim drop empties and rejoin losslessly" {
  assert_eq(@src.definition_of_done_lines("Tests pass\n\n  Review clean \n"), [
    "Tests pass", "Review clean",
  ])
  assert_eq(@src.definition_of_done_lines(""), [])
  assert_eq(@src.definition_of_done_lines("\n \n"), [])
  assert_eq(@src.definition_of_done_text(["a", "b"]), "a\nb")
  assert_eq(@src.definition_of_done_text([]), "")
  let lines = ["Deploy", "Verify"]
  assert_eq(
    @src.definition_of_done_lines(@src.definition_of_done_text(lines)),
    lines,
  )
}

///|
test "priority select options are fixed and wire derived" {
  let expected = [@client.Low, @client.Normal, @client.High, @client.Critical]
  assert_true(@src.priorities() == expected)
}
