# Board presentation helpers

These checked examples exercise the deterministic view helpers without a DOM.
The browser entry mounts `app()`; Warren validates that DOM-dependent entry.

```moonbit check
///|
test "connection labels and capped reconnect delays" {
  assert_eq(@src.connection_label(@src.Connecting), "Connecting")
  assert_eq(@src.connection_label(@src.Online), "Online")
  assert_eq(
    @src.connection_label(@src.ProtocolError("private detail")),
    "Protocol error",
  )
  assert_eq(@src.retry_delay(0), 250)
  assert_eq(@src.retry_delay(5), 8000)
  assert_eq(@src.retry_delay(99), 10000)
}
```

Lane order is fixed while grouping is derived from the replica, not a second
copy of Board state.

```moonbit check
///|
test "seven lanes and wire-independent labels" {
  assert_eq(@src.lanes().length(), 7)
  assert_eq(@src.stage_label(@client.Created), "Created")
  assert_eq(@src.stage_label(@client.Suspended), "Suspended")
  assert_eq(@src.priority_label(@client.Critical), "Critical")
  let replica = @client.BoardReplica::empty()
  assert_eq(@src.tasks_in_lane(replica, @client.Ready).length(), 0)
}
```

Loading and empty are distinct states: a replica without an authoritative
snapshot is unknown, not empty, and invalidation clears every record so no
stale cards survive a resync.

```moonbit check
///|
test "loading and empty presentation" {
  let replica = @client.BoardReplica::empty()
  assert_eq(@src.empty_message(replica), Some("Waiting for Board state"))
  assert_eq(@src.attempt_count(replica, "task-1"), 0)
  assert_eq(@src.attempt_indicator(replica, "task-1"), "No attempts")
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
  assert_eq(@src.empty_message(replica), Some("No Board tasks yet"))
}
```

Move suggestions mirror the Board v1 stage FSM as a UX convenience; the
durable server stays authoritative and may still reject a suggested move.

```moonbit check
///|
test "stage fsm suggestions" {
  assert_true(
    @src.move_suggestions(@client.Created) ==
    [@client.Refining, @client.Suspended],
  )
  assert_true(
    @src.move_suggestions(@client.Review) ==
    [@client.Done, @client.Ready, @client.Refining, @client.Suspended],
  )
  assert_eq(@src.move_suggestions(@client.Done).length(), 1)
}
```

Definition-of-done drafts split one entry per line: surrounding whitespace is
dropped, empty lines are removed, and cleaned entries rejoin losslessly for
editing.

```moonbit check
///|
test "definition of done round trip" {
  assert_eq(@src.definition_of_done_lines("Tests pass\n\n Review clean \n"), [
    "Tests pass", "Review clean",
  ])
  assert_eq(
    @src.definition_of_done_text(["Tests pass", "Review clean"]),
    "Tests pass\nReview clean",
  )
  assert_eq(@src.definition_of_done_text([]), "")
}
```

The editor priority select has a fixed option order and derives its wire
values from the client's centralized `to_wire`, never from local spellings.

```moonbit check
///|
test "priority options" {
  assert_eq(@src.priorities().length(), 4)
  assert_true(@src.priorities()[0] == @client.Low)
  assert_true(@src.priorities()[3] == @client.Critical)
}
```

Manual lifecycle controls only offer actions from authoritative status. The
server validates transitions; these helpers never execute work.

```moonbit check
///|
test "manual attempt options and authoritative status affordances" {
  assert_eq(@src.attempt_kinds().map(kind => kind.to_wire()), [
    "discuss", "execute", "review",
  ])
  assert_eq(@src.attempt_outcomes().map(outcome => outcome.to_wire()), [
    "succeeded", "failed", "cancelled", "interrupted",
  ])
  assert_eq(@src.outcome_label(@client.Interrupted), "Interrupted")
  assert_true(@src.attempt_startable(@client.Queued))
  assert_false(@src.attempt_startable(@client.Running))
  assert_true(@src.attempt_finishable(@client.Running))
  assert_false(@src.attempt_finishable(@client.Succeeded))
  assert_false(
    @src.queue_attempt_id_valid(@client.BoardReplica::empty(), "attempt-1"),
  )
}
```

Recording a review decision offers only the two terminal choices; `pending`
is the implicit running state and never a wire decision. Eligibility mirrors
the domain exactly, and a Running Review attempt without a decision only
warns on Finish.

```moonbit check
///|
test "review decision options and finish warning predicate" {
  assert_eq(@src.review_decisions().map(decision => decision.to_wire()), [
    "approved", "changes_requested",
  ])
  assert_eq(
    @src.review_decision_label(@client.ChangesRequested),
    "Request changes",
  )
}
```
