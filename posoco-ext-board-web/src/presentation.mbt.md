# Read-only Board presentation helpers

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

Empty replicas render a clear state without inventing tasks or attempts.

```moonbit check
///|
test "empty task and attempt presentation" {
  let replica = @client.BoardReplica::empty()
  assert_eq(@src.empty_message(replica), Some("No Board tasks yet"))
  assert_eq(@src.attempt_count(replica, "task-1"), 0)
  assert_eq(@src.attempt_indicator(replica, "task-1"), "No attempts")
}
```
