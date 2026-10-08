# Board client core

Checked examples for `@client` — the framework-neutral, in-memory Board
client core. Every `moonbit check` block below is type-checked by
`moon check` on both the native and JS targets; the behavioral assertions
mirroring these examples run as tests in `client_test.mbt`.

The replica starts without a baseline: a saved transport cursor alone is
never projected, so the first `hello` advertises an empty cursor.

```moonbit check
///|
test "empty replica" {
  let replica = @client.BoardReplica::empty()
  assert_false(replica.has_snapshot())
  assert_eq(replica.revision(), 0L)
  assert_eq(replica.last_seq(), 0L)
  let hello = replica.hello()
  assert_eq(hello.last_seq, 0L)
  assert_eq(hello.protocol_version, @protocol.protocol_version())
  assert_false(hello.has_board_snapshot)
}
```

Command results settle without touching the projection or the transport
cursor. Protocol errors surface only their stable code, never the raw
server message.

```moonbit check
///|
test "apply_frame" {
  let replica = @client.BoardReplica::empty()
  let outcome = replica.apply_frame(
    @protocol.CommandResult({
      command_id: "c1",
      accepted: false,
      error: Some("rejected"),
      current_revision: None,
    }),
  )
  assert_true(outcome is @client.CommandSettled(_))
  assert_eq(replica.revision(), 0L)
  assert_eq(replica.last_seq(), 0L)
  let terminal = replica.apply_frame(
    @protocol.Error(code="unauthorized", message="raw secret details"),
  )
  assert_true(terminal is @client.TerminalProtocolError("unauthorized"))
}
```

Malformed raw frames discard the baseline and ask for a fresh snapshot;
an unsupported protocol version reported by the codec is terminal instead.

```moonbit check
///|
test "apply_text" {
  let replica = @client.BoardReplica::empty()
  assert_true(replica.apply_text("not json") is @client.NeedsSnapshot(_))
  assert_false(replica.has_snapshot())
  let raw = Json::object({
    "type": Json::string("snapshot"),
    "protocol_version": Json::number(999),
    "last_seq": Json::number(0),
    "board_revision": Json::number(0),
    "payload": Json::object({}),
  }).stringify()
  assert_true(
    replica.apply_text(raw)
    is @client.TerminalProtocolError("unsupported_protocol_version"),
  )
}
```

A snapshot is the authoritative replacement. Its payload carries the whole
board plus the already-applied event suffix, which is validated but never
replayed into the records.

```moonbit check
///|
test "decode_board_snapshot" {
  let frame : @protocol.BoardSnapshot = {
    protocol_version: @protocol.protocol_version(),
    last_seq: 0L,
    board_revision: 0L,
    payload: Json::object({
      "board": Json::object({
        "revision": Json::number(0),
        "tasks": Json::array([]),
        "attempts": Json::array([]),
      }),
      "events": Json::array([]),
    }),
  }
  assert_true(@client.decode_board_snapshot(frame) is Ok(_))
}
```

The full walk-through: apply a snapshot, apply the next Board event, and
take a deep detached `copy` before mutating the copy. The original replica
stays untouched, so presentation layers can clone-on-update.

```moonbit check
///|
test "snapshot, event, and copy" {
  let replica = @client.BoardReplica::empty()
  let snapshot : @protocol.BoardSnapshot = {
    protocol_version: @protocol.protocol_version(),
    last_seq: 0L,
    board_revision: 1L,
    payload: Json::object({
      "board": Json::object({
        "revision": Json::number(1),
        "tasks": Json::array([]),
        "attempts": Json::array([]),
      }),
      "events": Json::array([]),
    }),
  }
  assert_true(replica.apply_snapshot(snapshot) is @client.Applied)
  let task = Json::object({
    "id": Json::string("t1"),
    "title": Json::string("Task t1"),
    "description": Json::string(""),
    "stage": Json::string("created"),
    "priority": Json::string("normal"),
    "definition_of_done": Json::array([]),
    "dependencies": Json::array([]),
    "created_at_ms": Json::number(1000),
    "updated_at_ms": Json::number(2000),
    "ready_since_ms": Json::null(),
  })
  let event : @protocol.BoardWireEvent = {
    seq: 1L,
    board_revision: 1L,
    kind: "board.task.created",
    scope: None,
    payload: Json::object({ "task_id": Json::string("t1"), "task": task }),
  }
  assert_true(replica.apply_event(event) is @client.Applied)
  assert_eq(replica.revision(), 1L)
  assert_eq(replica.last_seq(), 1L)
  let copy = replica.copy()
  assert_true(copy == replica)
  assert_eq(replica.tasks()[0].id, "t1")
  assert_true(replica.tasks()[0].stage is @client.Created)
}
```
