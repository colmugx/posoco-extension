///|
fn assert_baseline(
  replica : @client.BoardReplica,
  seq : Int64,
  revision : Int64,
) -> Unit raise {
  assert_true(replica.has_snapshot())
  assert_eq(replica.last_seq(), seq)
  assert_eq(replica.revision(), revision)
  assert_eq(replica.hello(), {
    protocol_version: @protocol.protocol_version(),
    last_seq: seq,
    has_board_snapshot: true,
  })
  assert_eq(replica.tasks().length(), 1)
  assert_eq(replica.attempts().length(), 1)
}

///|
fn assert_empty(replica : @client.BoardReplica) -> Unit raise {
  assert_false(replica.has_snapshot())
  assert_eq(replica.last_seq(), 0L)
  assert_eq(replica.revision(), 0L)
  assert_eq(replica.tasks().length(), 0)
  assert_eq(replica.attempts().length(), 0)
  assert_eq(replica.hello(), {
    protocol_version: @protocol.protocol_version(),
    last_seq: 0L,
    has_board_snapshot: false,
  })
}

///|
fn assert_step(
  replica : @client.BoardReplica,
  name : String,
  frame : @protocol.BoardServerFrame,
  outcome : @client.ApplyOutcome,
) -> Unit raise {
  match name {
    "snapshot" => {
      assert_true(outcome is @client.Applied)
      assert_baseline(replica, 2L, 2L)
      let task = replica.tasks()[0]
      assert_eq(task.id, "task-1")
      assert_eq(task.title, "Validate the Board contract")
      assert_eq(
        task.description,
        "Share wire fixtures across browser and desktop clients.",
      )
      assert_true(task.stage is @client.Created)
      assert_true(task.priority is @client.Normal)
      assert_eq(task.definition_of_done, [
        "Decode every v1 server frame", "Apply the authoritative projection",
      ])
      assert_eq(task.dependencies, [])
      assert_eq(task.created_at_ms, 1000L)
      assert_eq(task.updated_at_ms, 1000L)
      assert_eq(task.ready_since_ms, None)
      let attempt = replica.attempts()[0]
      assert_eq(attempt.id, "attempt-1")
      assert_eq(attempt.task_id, task.id)
      assert_true(attempt.kind is @client.Discuss)
      assert_true(attempt.status is @client.Queued)
      assert_true(attempt.review is None)
      assert_eq(attempt.created_at_ms, 1100L)
      assert_eq(attempt.updated_at_ms, 1100L)
      assert_eq(attempt.started_at_ms, None)
      assert_eq(attempt.finished_at_ms, None)
      match frame {
        Snapshot(snapshot) =>
          match snapshot.payload {
            { "events": Array(events), .. } => {
              assert_eq(events.length(), 2)
              match
                decode_fixture(
                  "snapshot retained history[0]",
                  events[0].stringify(),
                ) {
                Event(event) => {
                  assert_eq(event.seq, 1L)
                  assert_eq(event.board_revision, 1L)
                }
                _ => fail("Snapshot history must contain Event frames")
              }
            }
            _ => fail("Snapshot must contain its retained event suffix")
          }
        _ => fail("Expected snapshot fixture")
      }
    }
    "task-created" => {
      assert_true(outcome is @client.Duplicate)
      assert_baseline(replica, 2L, 2L)
      assert_eq(replica.tasks()[0].updated_at_ms, 1000L)
    }
    "task-updated" => {
      assert_true(outcome is @client.Applied)
      assert_baseline(replica, 3L, 3L)
      assert_eq(replica.tasks()[0].title, "Validate the Board contract — v1")
      assert_true(replica.tasks()[0].priority is @client.High)
      assert_eq(replica.tasks()[0].updated_at_ms, 1200L)
      assert_true(replica.attempts()[0].status is @client.Queued)
    }
    "attempt-started" => {
      assert_true(outcome is @client.Applied)
      assert_baseline(replica, 4L, 4L)
      assert_true(replica.attempts()[0].status is @client.Running)
      assert_eq(replica.attempts()[0].started_at_ms, Some(1300L))
      assert_eq(replica.attempts()[0].finished_at_ms, None)
      assert_eq(replica.attempts()[0].updated_at_ms, 1300L)
      assert_eq(replica.tasks()[0].updated_at_ms, 1200L)
    }
    "attempt-finished" => {
      assert_true(outcome is @client.Applied)
      assert_baseline(replica, 5L, 5L)
      assert_true(replica.attempts()[0].status is @client.Succeeded)
      assert_eq(replica.attempts()[0].started_at_ms, Some(1300L))
      assert_eq(replica.attempts()[0].finished_at_ms, Some(1400L))
      assert_eq(replica.attempts()[0].updated_at_ms, 1400L)
    }
    "telemetry" => {
      assert_true(outcome is @client.Applied)
      assert_baseline(replica, 6L, 5L)
      assert_eq(replica.tasks()[0].updated_at_ms, 1200L)
      assert_true(replica.attempts()[0].status is @client.Succeeded)
      match frame {
        Event(event) => {
          assert_eq(event.board_revision, 0L)
          assert_eq(
            event.scope,
            Some({
              session_id: Some("session-1"),
              run_id: Some("run-1"),
              turn_id: Some("turn-1"),
            }),
          )
        }
        _ => fail("Expected telemetry fixture")
      }
    }
    "command-result" =>
      match frame {
        CommandResult(result) => {
          assert_eq_eq(outcome, @client.CommandSettled(result))
          assert_eq(result.command_id, "command-1")
          assert_true(result.accepted)
          assert_eq(result.error, None)
          assert_eq(result.current_revision, Some(5L))
        }
        _ => fail("Expected command result fixture")
      }
    "resync-required" => {
      assert_eq_eq(outcome, @client.NeedsSnapshot("client_queue_overflow"))
      assert_empty(replica)
    }
    "protocol-error" =>
      assert_eq_eq(outcome, @client.TerminalProtocolError("hello_required"))
    _ => fail("Unrecognized canonical fixture")
  }
}

///|
async test "each canonical fixture decodes and reduces on an independent valid baseline" {
  let directory = fixture_directory()
  let cases : Array[(String, Array[String])] = [
    ("snapshot", []),
    ("task-created", ["snapshot"]),
    ("task-updated", ["snapshot"]),
    ("attempt-started", ["snapshot", "task-updated"]),
    ("attempt-finished", ["snapshot", "task-updated", "attempt-started"]),
    (
      "telemetry",
      ["snapshot", "task-updated", "attempt-started", "attempt-finished"],
    ),
    ("command-result", ["snapshot"]),
    ("resync-required", ["snapshot"]),
    ("protocol-error", ["snapshot"]),
  ]
  for (name, predecessors) in cases {
    let replica = @client.BoardReplica::empty()
    assert_empty(replica)
    for predecessor in predecessors {
      assert_true(
        replica.apply_frame(fixture_frame(directory, predecessor))
        is @client.Applied,
      )
    }
    let tasks_before = replica.tasks()
    let attempts_before = replica.attempts()
    let seq_before = replica.last_seq()
    let revision_before = replica.revision()
    let frame = fixture_frame(directory, name)
    assert_step(replica, name, frame, replica.apply_frame(frame))
    if name == "command-result" {
      assert_eq_eq(replica.tasks(), tasks_before)
      assert_eq_eq(replica.attempts(), attempts_before)
      assert_eq(replica.last_seq(), seq_before)
      assert_eq(replica.revision(), revision_before)
    }
  }
}

///|
async fn canonical_chain(via_text : Bool) -> Unit {
  let directory = fixture_directory()
  let replica = @client.BoardReplica::empty()
  assert_empty(replica)
  for name in fixture_names {
    let text = fixture_text(directory, name)
    let frame = decode_fixture(name, text)
    let tasks_before = replica.tasks()
    let attempts_before = replica.attempts()
    let seq_before = replica.last_seq()
    let revision_before = replica.revision()
    let outcome = if via_text {
      replica.apply_text(text)
    } else {
      replica.apply_frame(frame)
    }
    assert_step(replica, name, frame, outcome)
    if name == "telemetry" || name == "command-result" || name == "task-created" {
      assert_eq_eq(replica.tasks(), tasks_before)
      assert_eq_eq(replica.attempts(), attempts_before)
      if name != "telemetry" {
        assert_eq(replica.last_seq(), seq_before)
      }
      assert_eq(replica.revision(), revision_before)
    }
  }
}

///|
async test "canonical decoded chain preserves projection and transport invariants" {
  canonical_chain(false)
}

///|
async test "canonical text chain agrees with decoded frame reduction" {
  canonical_chain(true)
}

///|
async test "standalone creation applies from an authoritative empty baseline then duplicates" {
  let replica = @client.BoardReplica::empty()
  let baseline = decode_fixture(
    "embedded empty baseline", "{\"type\":\"snapshot\",\"protocol_version\":1,\"last_seq\":0,\"board_revision\":0,\"payload\":{\"board\":{\"revision\":0,\"tasks\":[],\"attempts\":[]},\"events\":[]}}",
  )
  assert_true(replica.apply_frame(baseline) is @client.Applied)
  let frame = fixture_frame(fixture_directory(), "task-created")
  assert_true(replica.apply_frame(frame) is @client.Applied)
  assert_eq(replica.tasks().length(), 1)
  assert_eq(replica.tasks()[0].id, "task-1")
  assert_eq(replica.attempts().length(), 0)
  assert_eq(replica.revision(), 1L)
  assert_eq(replica.last_seq(), 1L)
  assert_true(replica.apply_frame(frame) is @client.Duplicate)
  assert_eq(replica.tasks().length(), 1)
  assert_eq(replica.revision(), 1L)
  assert_eq(replica.last_seq(), 1L)
}
