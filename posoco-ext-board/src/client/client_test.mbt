///|
/// Test-only Eq assertion for the client read models, which intentionally
/// derive `Eq` without `Debug`. Same equality contract as the builtin
/// `assert_eq`; failures are reported at the call site.
#callsite(autofill(loc))
fn[T : Eq] assert_eq_eq(
  actual : T,
  expected : T,
  loc~ : SourceLoc,
) -> Unit raise {
  if actual != expected {
    fail("assertion failed: actual == expected", loc~)
  }
}

///|
fn wire_task(
  id~ : String = "t1",
  stage~ : String = "created",
  priority~ : String = "normal",
  dod~ : Array[Json] = ["unit tests"],
  deps~ : Array[Json] = [],
  created~ : Json = Json::number(1000),
  updated~ : Json = Json::number(2000),
  ready~ : Json = Json::null(),
  model~ : Json = Json::null(),
  review~ : Json = Json::null(),
  review_feedback~ : Json = Json::null(),
) -> Json {
  Json::object({
    "id": Json::string(id),
    "title": Json::string("Task \{id}"),
    "description": Json::string("Board task \{id}"),
    "stage": Json::string(stage),
    "priority": Json::string(priority),
    "definition_of_done": Json::array(dod),
    "dependencies": Json::array(deps),
    "created_at_ms": created,
    "updated_at_ms": updated,
    "ready_since_ms": ready,
    "model": model,
    "review": review,
    "review_feedback": review_feedback,
  })
}

///|
fn wire_attempt(
  id~ : String = "a1",
  task_id~ : String = "t1",
  kind~ : String = "execute",
  status~ : String = "queued",
  review~ : Json = Json::null(),
  started~ : Json = Json::null(),
  finished~ : Json = Json::null(),
) -> Json {
  Json::object({
    "id": Json::string(id),
    "task_id": Json::string(task_id),
    "kind": Json::string(kind),
    "status": Json::string(status),
    "review": review,
    "created_at_ms": Json::number(1000),
    "started_at_ms": started,
    "finished_at_ms": finished,
    "updated_at_ms": Json::number(2000),
  })
}

///|
fn task_payload(task~ : Json = wire_task(), task_id~ : String = "t1") -> Json {
  Json::object({
    "task_id": Json::string(task_id),
    "task": task,
    "at_ms": Json::number(3000),
  })
}

///|
fn attempt_payload(
  attempt~ : Json = wire_attempt(),
  attempt_id~ : String = "a1",
  task_id~ : String = "t1",
) -> Json {
  Json::object({
    "attempt_id": Json::string(attempt_id),
    "task_id": Json::string(task_id),
    "attempt": attempt,
  })
}

///|
fn task_event(
  seq~ : Int64,
  revision~ : Int64,
  kind~ : String = "board.task.created",
  task~ : Json = wire_task(),
  task_id~ : String = "t1",
) -> @protocol.BoardWireEvent {
  {
    seq,
    board_revision: revision,
    kind,
    scope: None,
    payload: task_payload(task~, task_id~),
  }
}

///|
fn attempt_event(
  seq~ : Int64,
  revision~ : Int64,
  kind~ : String = "board.attempt.queued",
  attempt~ : Json = wire_attempt(),
  attempt_id~ : String = "a1",
  task_id~ : String = "t1",
) -> @protocol.BoardWireEvent {
  {
    seq,
    board_revision: revision,
    kind,
    scope: None,
    payload: attempt_payload(attempt~, attempt_id~, task_id~),
  }
}

///|
fn suffix_event(
  seq~ : Int64,
  revision~ : Int64,
  kind~ : String,
  payload~ : Json,
) -> Json {
  Json::object({
    "type": Json::string("event"),
    "seq": Json::number(seq.to_double()),
    "board_revision": Json::number(revision.to_double()),
    "kind": Json::string(kind),
    "payload": payload,
  })
}

///|
fn snapshot_frame(
  revision~ : Int64,
  last_seq~ : Int64,
  tasks~ : Array[Json] = [],
  attempts~ : Array[Json] = [],
  events~ : Array[Json] = [],
) -> @protocol.BoardSnapshot {
  {
    protocol_version: @protocol.protocol_version(),
    last_seq,
    board_revision: revision,
    payload: Json::object({
      "board": Json::object({
        "revision": Json::number(revision.to_double()),
        "tasks": Json::array(tasks),
        "attempts": Json::array(attempts),
      }),
      "events": Json::array(events),
    }),
  }
}

///|
fn seeded(
  revision~ : Int64 = 1L,
  last_seq~ : Int64 = 1L,
  suffix~ : Array[Json] = [
    suffix_event(
      seq=1L,
      revision=1L,
      kind="board.task.created",
      payload=task_payload(task=wire_task(), task_id="t1"),
    ),
  ],
) -> @client.BoardReplica raise {
  let replica = @client.BoardReplica::empty()
  assert_true(
    replica.apply_snapshot(
      snapshot_frame(
        revision~,
        last_seq~,
        tasks=[wire_task()],
        attempts=[wire_attempt()],
        events=suffix,
      ),
    )
    is @client.Applied,
  )
  replica
}

///|
test "empty replica advertises no baseline and the current protocol version" {
  let replica = @client.BoardReplica::empty()
  assert_false(replica.has_snapshot())
  assert_eq_eq(replica.revision(), 0L)
  assert_eq_eq(replica.last_seq(), 0L)
  assert_eq_eq(replica.tasks().length(), 0)
  assert_eq_eq(replica.attempts().length(), 0)
  let hello = replica.hello()
  assert_eq_eq(hello.last_seq, 0L)
  assert_eq_eq(hello.protocol_version, @protocol.protocol_version())
  assert_false(hello.has_board_snapshot)
}

///|
test "decode_board_snapshot maps every client enum value strictly" {
  let tasks = [
    wire_task(id="t1", stage="created", priority="low"),
    wire_task(id="t2", stage="refining", priority="normal"),
    wire_task(id="t3", stage="ready", priority="high", ready=Json::number(42)),
    wire_task(id="t4", stage="running", priority="critical"),
    wire_task(id="t5", stage="review"),
    wire_task(id="t6", stage="done"),
    wire_task(id="t7", stage="suspended"),
    wire_task(id="t8", stage="cancelled"),
  ]
  let attempts = [
    wire_attempt(id="a1", kind="discuss", status="queued"),
    wire_attempt(
      id="a2",
      kind="execute",
      status="running",
      review=Json::string("pending"),
      started=Json::number(5),
    ),
    wire_attempt(
      id="a3",
      kind="review",
      status="succeeded",
      review=Json::string("approved"),
      finished=Json::number(9),
    ),
    wire_attempt(
      id="a4",
      status="failed",
      review=Json::string("changes_requested"),
    ),
    wire_attempt(id="a5", status="cancelled"),
    wire_attempt(id="a6", status="interrupted"),
  ]
  let frame = snapshot_frame(revision=3L, last_seq=0L, tasks~, attempts~)
  guard @client.decode_board_snapshot(frame) is Ok(decoded) else {
    abort("expected a valid snapshot")
  }
  assert_eq_eq(decoded.revision, 3L)
  assert_eq_eq(decoded.last_seq, 0L)
  assert_eq_eq(decoded.tasks.map(task => task.stage), [
    @client.Created,
    @client.Refining,
    @client.Ready,
    @client.Running,
    @client.Review,
    @client.Done,
    @client.Suspended,
    @client.Cancelled,
  ])
  assert_eq_eq(decoded.tasks.map(task => task.priority), [
    @client.Low,
    @client.Normal,
    @client.High,
    @client.Critical,
    @client.Normal,
    @client.Normal,
    @client.Normal,
    @client.Normal,
  ])
  assert_eq_eq(decoded.tasks[2].ready_since_ms, Some(42L))
  assert_eq_eq(decoded.tasks[0].ready_since_ms, None)
  assert_eq_eq(decoded.attempts.map(attempt => attempt.kind), [
    @client.Discuss,
    @client.Execute,
    @client.Review,
    @client.Execute,
    @client.Execute,
    @client.Execute,
  ])
  assert_eq_eq(decoded.attempts.map(attempt => attempt.status), [
    @client.Queued,
    @client.Running,
    @client.Succeeded,
    @client.Failed,
    @client.Cancelled,
    @client.Interrupted,
  ])
  assert_eq_eq(decoded.attempts.map(attempt => attempt.review), [
    None,
    Some(@client.Pending),
    Some(@client.Approved),
    Some(@client.ChangesRequested),
    None,
    None,
  ])
  assert_eq_eq(decoded.attempts[1].started_at_ms, Some(5L))
  assert_eq_eq(decoded.attempts[2].finished_at_ms, Some(9L))
}

///|
test "all eight board event kinds upsert full entities in place" {
  let replica = seeded(last_seq=1L)
  assert_eq_eq(
    replica.apply_event(
      task_event(seq=2L, revision=2L, task=wire_task(id="t2"), task_id="t2"),
    ),
    @client.Applied,
  )
  assert_eq_eq(
    replica.apply_event(
      task_event(
        seq=3L,
        revision=2L,
        kind="board.task.updated",
        task=wire_task(id="t1", stage="ready", ready=Json::number(77)),
      ),
    ),
    @client.Applied,
  )
  assert_eq_eq(
    replica.apply_event(
      task_event(
        seq=4L,
        revision=3L,
        kind="board.task.dependencies_changed",
        task=wire_task(id="t1", stage="ready", deps=[Json::string("t2")]),
      ),
    ),
    @client.Applied,
  )
  assert_eq_eq(
    replica.apply_event(
      task_event(
        seq=5L,
        revision=3L,
        kind="board.task.stage_changed",
        task=wire_task(id="t2", stage="running"),
        task_id="t2",
      ),
    ),
    @client.Applied,
  )
  assert_eq_eq(
    replica.apply_event(
      attempt_event(
        seq=6L,
        revision=3L,
        kind="board.attempt.queued",
        attempt=wire_attempt(status="queued"),
      ),
    ),
    @client.Applied,
  )
  assert_eq_eq(replica.attempts()[0].status, @client.Queued)
  assert_eq_eq(
    replica.apply_event(
      attempt_event(
        seq=7L,
        revision=3L,
        kind="board.attempt.started",
        attempt=wire_attempt(status="running", started=Json::number(4000)),
      ),
    ),
    @client.Applied,
  )
  assert_eq_eq(replica.attempts()[0].status, @client.Running)
  assert_eq_eq(replica.attempts()[0].started_at_ms, Some(4000L))
  assert_eq_eq(
    replica.apply_event(
      attempt_event(
        seq=8L,
        revision=4L,
        kind="board.attempt.finished",
        attempt=wire_attempt(status="succeeded", finished=Json::number(5000)),
      ),
    ),
    @client.Applied,
  )
  assert_eq_eq(
    replica.apply_event(
      attempt_event(
        seq=9L,
        revision=4L,
        kind="board.review.recorded",
        attempt=wire_attempt(
          kind="review",
          status="succeeded",
          review=Json::string("approved"),
        ),
      ),
    ),
    @client.Applied,
  )
  assert_eq_eq(replica.revision(), 4L)
  assert_eq_eq(replica.last_seq(), 9L)
  let tasks = replica.tasks()
  assert_eq_eq(tasks.length(), 2)
  assert_eq_eq(tasks[0].id, "t1")
  assert_eq_eq(tasks[0].stage, @client.Ready)
  assert_eq_eq(tasks[0].dependencies, ["t2"])
  assert_eq_eq(tasks[1].id, "t2")
  assert_eq_eq(tasks[1].stage, @client.Running)
  let attempts = replica.attempts()
  assert_eq_eq(attempts.length(), 1)
  assert_eq_eq(attempts[0].status, @client.Succeeded)
  assert_eq_eq(attempts[0].review, Some(@client.Approved))
}

///|
test "same and next board revision are accepted, a later revision invalidates" {
  let replica = seeded(revision=2L)
  assert_eq_eq(
    replica.apply_event(
      task_event(seq=2L, revision=2L, task=wire_task(id="t2"), task_id="t2"),
    ),
    @client.Applied,
  )
  assert_eq_eq(
    replica.apply_event(
      task_event(seq=3L, revision=3L, task=wire_task(id="t3"), task_id="t3"),
    ),
    @client.Applied,
  )
  assert_eq_eq(replica.revision(), 3L)
  assert_eq_eq(
    replica.apply_event(
      task_event(seq=4L, revision=5L, task=wire_task(id="t4"), task_id="t4"),
    ),
    @client.NeedsSnapshot("board revision discontinuity"),
  )
  assert_false(replica.has_snapshot())
  assert_eq_eq(replica.revision(), 0L)
  assert_eq_eq(replica.last_seq(), 0L)
  assert_eq_eq(replica.tasks().length(), 0)
}

///|
test "revision regression invalidates the baseline" {
  let replica = seeded(revision=4L)
  assert_eq_eq(
    replica.apply_event(task_event(seq=2L, revision=3L)),
    @client.NeedsSnapshot("board revision discontinuity"),
  )
  assert_false(replica.has_snapshot())
}

///|
test "duplicates are ignored before payload or revision are inspected" {
  let replica = seeded()
  assert_eq_eq(
    replica.apply_event(
      task_event(
        seq=1L,
        revision=99L,
        kind="board.unknown.kind",
        task=Json::number(1),
      ),
    ),
    @client.Duplicate,
  )
  assert_true(replica.has_snapshot())
  assert_eq_eq(replica.last_seq(), 1L)
  assert_eq_eq(replica.revision(), 1L)
  assert_eq_eq(replica.tasks().length(), 1)
}

///|
test "sequence gaps and jumps invalidate, older seq is a duplicate" {
  let replica = seeded()
  assert_eq_eq(
    replica.apply_event(task_event(seq=3L, revision=1L)),
    @client.NeedsSnapshot("event sequence gap"),
  )
  assert_false(replica.has_snapshot())
  assert_eq_eq(replica.last_seq(), 0L)
  let jumped = seeded()
  assert_eq_eq(
    jumped.apply_event(task_event(seq=7L, revision=1L)),
    @client.NeedsSnapshot("event sequence gap"),
  )
  assert_eq_eq(jumped.last_seq(), 0L)
  let older = seeded(last_seq=2L, suffix=[
    suffix_event(
      seq=1L,
      revision=1L,
      kind="runtime.telemetry.tick",
      payload=Json::null(),
    ),
    suffix_event(
      seq=2L,
      revision=1L,
      kind="board.task.created",
      payload=task_payload(task=wire_task(), task_id="t1"),
    ),
  ])
  assert_eq_eq(
    older.apply_event(task_event(seq=1L, revision=1L)),
    @client.Duplicate,
  )
  assert_eq_eq(older.last_seq(), 2L)
  assert_true(older.has_snapshot())
}

///|
test "board events without a baseline invalidate instead of projecting" {
  let replica = @client.BoardReplica::empty()
  assert_eq_eq(
    replica.apply_event(task_event(seq=1L, revision=1L)),
    @client.NeedsSnapshot("board event requires snapshot"),
  )
  assert_eq_eq(replica.last_seq(), 0L)
  assert_false(replica.has_snapshot())
}

///|
test "non-board telemetry advances only the sequence and ignores payload" {
  let replica = @client.BoardReplica::empty()
  let event : @protocol.BoardWireEvent = {
    seq: 1L,
    board_revision: 5L,
    kind: "runtime.telemetry.tick",
    scope: None,
    payload: Json::string("not even an object"),
  }
  assert_eq_eq(replica.apply_event(event), @client.Applied)
  assert_eq_eq(replica.last_seq(), 1L)
  assert_eq_eq(replica.revision(), 0L)
  assert_false(replica.has_snapshot())
  assert_eq_eq(replica.apply_event({ ..event, seq: 2L, }), @client.Applied)
  assert_eq_eq(replica.last_seq(), 2L)
  assert_eq_eq(replica.hello().last_seq, 2L)
  assert_false(replica.hello().has_board_snapshot)
}

///|
test "unknown board event kinds invalidate the baseline" {
  let replica = seeded()
  assert_eq_eq(
    replica.apply_event(
      task_event(seq=2L, revision=1L, kind="board.task.teleported"),
    ),
    @client.NeedsSnapshot("unknown board event"),
  )
  assert_false(replica.has_snapshot())
  assert_eq_eq(replica.tasks().length(), 0)
}

///|
test "snapshot is an authoritative replacement, never a suffix replay" {
  let ghost = task_payload(
    task=wire_task(id="ghost", stage="done"),
    task_id="ghost",
  )
  let frame = snapshot_frame(
    revision=9L,
    last_seq=2L,
    tasks=[wire_task(id="kept", stage="refining")],
    attempts=[wire_attempt(id="kept-a", task_id="kept")],
    events=[
      suffix_event(
        seq=1L,
        revision=9L,
        kind="board.task.created",
        payload=ghost,
      ),
      suffix_event(
        seq=2L,
        revision=9L,
        kind="board.task.updated",
        payload=ghost,
      ),
    ],
  )
  let replica = seeded(last_seq=1L)
  assert_eq_eq(replica.apply_snapshot(frame), @client.Applied)
  assert_eq_eq(replica.revision(), 9L)
  assert_eq_eq(replica.last_seq(), 2L)
  assert_true(replica.has_snapshot())
  assert_eq_eq(replica.tasks().map(task => task.id), ["kept"])
  assert_eq_eq(replica.attempts().map(attempt => attempt.id), ["kept-a"])
}

///|
test "snapshot replacement re-records the authoritative view" {
  let replica = seeded(last_seq=1L)
  let frame = snapshot_frame(
    revision=7L,
    last_seq=5L,
    tasks=[wire_task(id="fresh", stage="ready", ready=Json::number(11))],
    attempts=[wire_attempt(id="fresh-a", task_id="fresh", status="running")],
    events=[
      suffix_event(
        seq=1L,
        revision=6L,
        kind="runtime.telemetry.tick",
        payload=Json::null(),
      ),
      suffix_event(
        seq=2L,
        revision=6L,
        kind="runtime.telemetry.tick",
        payload=Json::null(),
      ),
      suffix_event(
        seq=3L,
        revision=7L,
        kind="runtime.telemetry.tick",
        payload=Json::null(),
      ),
      suffix_event(
        seq=4L,
        revision=7L,
        kind="runtime.telemetry.tick",
        payload=Json::null(),
      ),
      suffix_event(
        seq=5L,
        revision=7L,
        kind="runtime.telemetry.tick",
        payload=Json::null(),
      ),
    ],
  )
  assert_eq_eq(replica.apply_snapshot(frame), @client.Applied)
  assert_eq_eq(replica.revision(), 7L)
  assert_eq_eq(replica.last_seq(), 5L)
  assert_eq_eq(replica.tasks().map(task => task.id), ["fresh"])
  assert_eq_eq(replica.tasks()[0].ready_since_ms, Some(11L))
  let hello = replica.hello()
  assert_eq_eq(hello.last_seq, 5L)
  assert_true(hello.has_board_snapshot)
}

///|
test "snapshot suffix validation rejects malformed transport history" {
  let entity = task_payload(task=wire_task(id="s1"), task_id="s1")
  let valid = snapshot_frame(
    revision=2L,
    last_seq=2L,
    tasks=[wire_task(id="s1")],
    events=[
      suffix_event(
        seq=1L,
        revision=2L,
        kind="board.task.created",
        payload=entity,
      ),
      suffix_event(
        seq=2L,
        revision=2L,
        kind="board.task.updated",
        payload=entity,
      ),
    ],
  )
  assert_true(@client.decode_board_snapshot(valid) is Ok(_))
  assert_true(
    @client.decode_board_snapshot({ ..valid, last_seq: 1L, })
    is Err(@client.InvalidData(_)),
  )
  assert_true(
    @client.decode_board_snapshot({ ..valid, board_revision: 3L, })
    is Err(@client.InvalidData(_)),
  )
  assert_true(
    @client.decode_board_snapshot(
      snapshot_frame(revision=2L, last_seq=3L, events=[
        suffix_event(
          seq=1L,
          revision=2L,
          kind="board.task.created",
          payload=entity,
        ),
      ]),
    )
    is Err(@client.InvalidData(_)),
  )
  assert_true(
    @client.decode_board_snapshot(snapshot_frame(revision=2L, last_seq=1L))
    is Err(@client.InvalidData(_)),
  )
  assert_true(
    @client.decode_board_snapshot(
      snapshot_frame(revision=2L, last_seq=2L, events=[
        suffix_event(
          seq=5L,
          revision=2L,
          kind="board.task.created",
          payload=entity,
        ),
        suffix_event(
          seq=6L,
          revision=2L,
          kind="board.task.updated",
          payload=entity,
        ),
      ]),
    )
    is Err(@client.InvalidData(_)),
  )
  assert_true(
    @client.decode_board_snapshot(
      snapshot_frame(revision=2L, last_seq=3L, events=[
        suffix_event(
          seq=1L,
          revision=2L,
          kind="board.task.created",
          payload=entity,
        ),
        suffix_event(
          seq=3L,
          revision=2L,
          kind="board.task.updated",
          payload=entity,
        ),
      ]),
    )
    is Err(@client.InvalidData(_)),
  )
  assert_true(
    @client.decode_board_snapshot(
      snapshot_frame(revision=2L, last_seq=2L, events=[
        suffix_event(
          seq=1L,
          revision=2L,
          kind="board.task.created",
          payload=entity,
        ),
        Json::object({
          "type": Json::string("command_result"),
          "command_id": Json::string("c1"),
          "accepted": Json::boolean(true),
        }),
      ]),
    )
    is Err(@client.InvalidData(_)),
  )
  assert_true(
    @client.decode_board_snapshot(
      snapshot_frame(revision=2L, last_seq=2L, events=[
        suffix_event(
          seq=1L,
          revision=2L,
          kind="board.task.created",
          payload=entity,
        ),
        Json::object({
          "type": Json::string("resync_required"),
          "reason": Json::string("server restart"),
          "current_seq": Json::number(2),
        }),
      ]),
    )
    is Err(@client.InvalidData(_)),
  )
  assert_true(
    @client.decode_board_snapshot(
      snapshot_frame(revision=2L, last_seq=2L, events=[
        suffix_event(
          seq=1L,
          revision=2L,
          kind="board.task.created",
          payload=entity,
        ),
        suffix_event(
          seq=2L,
          revision=2L,
          kind="runtime.telemetry.tick",
          payload=Json::null(),
        ),
      ]),
    )
    is Ok(_),
  )
}

///|
test "unsupported snapshot protocol version is a terminal client error" {
  let frame = {
    ..snapshot_frame(revision=0L, last_seq=0L),
    protocol_version: @protocol.protocol_version() + 1,
  }
  assert_eq_eq(
    @client.decode_board_snapshot(frame),
    Err(@client.UnsupportedProtocolVersion),
  )
  let replica = @client.BoardReplica::empty()
  assert_eq_eq(
    replica.apply_snapshot(frame),
    @client.TerminalProtocolError("unsupported_protocol_version"),
  )
  assert_false(replica.has_snapshot())
}

///|
test "snapshot records must be complete and strictly typed" {
  let replica = @client.BoardReplica::empty()
  let missing_title = wire_task()
  guard missing_title is Json::Object(missing_fields) else { abort("object") }
  missing_fields.remove("title")
  let no_ready = wire_task()
  guard no_ready is Json::Object(no_ready_fields) else { abort("object") }
  no_ready_fields.remove("ready_since_ms")
  let invalid_tasks = [
    missing_title,
    wire_task(stage="archived"),
    wire_task(priority="urgent"),
    wire_task(stage=""),
    wire_task(updated=Json::number(-5)),
    wire_task(updated=Json::number(2.5)),
    wire_task(updated=Json::number(9007199254740992)),
    wire_task(updated=Json::string("2000")),
    no_ready,
    wire_task(dod=["ok", Json::number(1)]),
    wire_task(deps=[Json::number(2)]),
  ]
  for payload in invalid_tasks {
    let frame = snapshot_frame(revision=1L, last_seq=0L, tasks=[payload])
    assert_true(replica.apply_snapshot(frame) is @client.NeedsSnapshot(_))
    assert_false(replica.has_snapshot())
  }
}

///|
test "attempt records require nullable fields to be present" {
  let replica = @client.BoardReplica::empty()
  let no_review = wire_attempt()
  guard no_review is Json::Object(review_fields) else { abort("object") }
  review_fields.remove("review")
  let no_started = wire_attempt()
  guard no_started is Json::Object(started_fields) else { abort("object") }
  started_fields.remove("started_at_ms")
  let no_finished = wire_attempt()
  guard no_finished is Json::Object(finished_fields) else { abort("object") }
  finished_fields.remove("finished_at_ms")
  let invalid_attempts = [
    no_review,
    no_started,
    no_finished,
    wire_attempt(status="paused"),
    wire_attempt(kind="plan"),
    wire_attempt(review=Json::string("rejected")),
    wire_attempt(started=Json::string("x")),
  ]
  for payload in invalid_attempts {
    let frame = snapshot_frame(revision=1L, last_seq=0L, attempts=[payload])
    assert_true(replica.apply_snapshot(frame) is @client.NeedsSnapshot(_))
    assert_false(replica.has_snapshot())
  }
}

///|
test "event entity payloads must be complete and strictly typed" {
  let replica = seeded()
  let missing_entity : @protocol.BoardWireEvent = {
    seq: 2L,
    board_revision: 1L,
    kind: "board.task.created",
    scope: None,
    payload: Json::object({
      "task_id": Json::string("t1"),
      "at_ms": Json::number(3000),
    }),
  }
  assert_eq_eq(
    replica.apply_event(missing_entity),
    @client.NeedsSnapshot("missing field: task"),
  )
  assert_false(replica.has_snapshot())
  let reseeded = seeded()
  assert_eq_eq(
    reseeded.apply_event(
      task_event(seq=2L, revision=1L, task=wire_task(stage="vanished")),
    ),
    @client.NeedsSnapshot("unknown task stage"),
  )
  assert_false(reseeded.has_snapshot())
  assert_eq_eq(reseeded.last_seq(), 0L)
}

///|
test "event metadata mismatches invalidate instead of misprojecting" {
  let first = seeded()
  assert_eq_eq(
    first.apply_event(
      task_event(seq=2L, revision=1L, task=wire_task(id="other")),
    ),
    @client.NeedsSnapshot("task metadata mismatch"),
  )
  let second = seeded()
  assert_eq_eq(
    second.apply_event(
      attempt_event(seq=2L, revision=1L, attempt=wire_attempt(id="different")),
    ),
    @client.NeedsSnapshot("attempt metadata mismatch"),
  )
  let third = seeded()
  assert_eq_eq(
    third.apply_event(
      attempt_event(seq=2L, revision=1L, attempt=wire_attempt(), task_id="t2"),
    ),
    @client.NeedsSnapshot("attempt metadata mismatch"),
  )
  for replica in [first, second, third] {
    assert_false(replica.has_snapshot())
    assert_eq_eq(replica.tasks().length(), 0)
  }
}

///|
test "matching attempt metadata projects across task changes" {
  let replica = seeded()
  assert_eq_eq(
    replica.apply_event(
      attempt_event(
        seq=2L,
        revision=1L,
        attempt=wire_attempt(task_id="t9"),
        task_id="t9",
      ),
    ),
    @client.Applied,
  )
  assert_eq_eq(replica.attempts().map(attempt => attempt.task_id), ["t9"])
}

///|
test "command results settle without projection or cursor changes" {
  let replica = seeded()
  let outcome = replica.apply_frame(
    @protocol.CommandResult({
      command_id: "c1",
      accepted: true,
      error: None,
      current_revision: Some(2L),
    }),
  )
  guard outcome is @client.CommandSettled(result) else { abort("settled") }
  assert_eq_eq(result.command_id, "c1")
  assert_true(result.accepted)
  assert_eq_eq(result.current_revision, Some(2L))
  assert_eq_eq(replica.revision(), 1L)
  assert_eq_eq(replica.last_seq(), 1L)
  assert_true(replica.has_snapshot())
  assert_eq_eq(replica.tasks().length(), 1)
}

///|
test "resync_required clears the replica to an empty unbaselined state" {
  let replica = seeded()
  assert_eq_eq(
    replica.apply_frame(
      @protocol.ResyncRequired(reason="server restart", current_seq=0L),
    ),
    @client.NeedsSnapshot("server restart"),
  )
  assert_eq_eq(replica.revision(), 0L)
  assert_eq_eq(replica.last_seq(), 0L)
  assert_false(replica.has_snapshot())
  assert_eq_eq(replica.tasks().length(), 0)
  assert_eq_eq(replica.attempts().length(), 0)
  let hello = replica.hello()
  assert_eq_eq(hello.last_seq, 0L)
  assert_false(hello.has_board_snapshot)
}

///|
test "protocol errors are terminal and expose only the stable code" {
  let replica = seeded()
  assert_eq_eq(
    replica.apply_frame(
      @protocol.Error(code="unauthorized", message="raw secret details"),
    ),
    @client.TerminalProtocolError("unauthorized"),
  )
  assert_true(replica.has_snapshot())
  assert_eq_eq(replica.last_seq(), 1L)
  assert_eq_eq(replica.tasks().length(), 1)
}

///|
test "malformed raw frames invalidate the baseline" {
  let replica = seeded()
  let raw_frames = [
    "not json", "42", "[1,2,3]", "{\"type\":\"mystery\"}", "{\"type\":\"event\"}",
    "{\"type\":\"error\",\"message\":\"missing code\"}",
  ]
  for raw in raw_frames {
    assert_true(replica.apply_text(raw) is @client.NeedsSnapshot(_))
    assert_false(replica.has_snapshot())
  }
  assert_eq_eq(replica.last_seq(), 0L)
  assert_eq_eq(replica.tasks().length(), 0)
}

///|
test "raw frames with an unsupported protocol version are terminal" {
  let replica = seeded()
  let raw = Json::object({
    "type": Json::string("snapshot"),
    "protocol_version": Json::number(999),
    "last_seq": Json::number(0),
    "board_revision": Json::number(0),
    "payload": Json::object({}),
  }).stringify()
  assert_eq_eq(
    replica.apply_text(raw),
    @client.TerminalProtocolError("unsupported_protocol_version"),
  )
  assert_false(replica.has_snapshot())
  assert_eq_eq(replica.last_seq(), 0L)
  assert_true(replica.tasks().is_empty())
}

///|
test "raw valid frames apply like decoded frames" {
  let replica = @client.BoardReplica::empty()
  let raw = Json::object({
    "type": Json::string("snapshot"),
    "protocol_version": Json::number(@protocol.protocol_version().to_double()),
    "last_seq": Json::number(0),
    "board_revision": Json::number(4),
    "payload": Json::object({
      "board": Json::object({
        "revision": Json::number(4),
        "tasks": Json::array([wire_task(id="raw", stage="done")]),
        "attempts": Json::array([]),
      }),
      "events": Json::array([]),
    }),
  }).stringify()
  assert_eq_eq(replica.apply_text(raw), @client.Applied)
  assert_eq_eq(replica.revision(), 4L)
  assert_eq_eq(replica.tasks().map(task => task.id), ["raw"])
}

///|
test "safe integer boundaries are enforced on records and counters" {
  let replica = @client.BoardReplica::empty()
  let boundary = wire_task(
    created=Json::number(9007199254740991),
    ready=Json::number(9007199254740991),
  )
  assert_eq_eq(
    replica.apply_snapshot(
      snapshot_frame(revision=1L, last_seq=0L, tasks=[boundary]),
    ),
    @client.Applied,
  )
  assert_eq_eq(replica.tasks()[0].created_at_ms, 9007199254740991L)
  assert_eq_eq(replica.tasks()[0].ready_since_ms, Some(9007199254740991L))
  assert_true(
    replica.apply_snapshot(
      snapshot_frame(revision=1L, last_seq=0L, tasks=[
        wire_task(created=Json::number(9007199254740992)),
      ]),
    )
    is @client.NeedsSnapshot(_),
  )
  assert_true(
    replica.apply_snapshot(snapshot_frame(revision=1L, last_seq=-1L))
    is @client.NeedsSnapshot(_),
  )
  assert_true(
    replica.apply_snapshot(snapshot_frame(revision=-2L, last_seq=0L))
    is @client.NeedsSnapshot(_),
  )
}

///|
test "snapshot board revision must match the frame revision" {
  let replica = @client.BoardReplica::empty()
  let frame = snapshot_frame(revision=3L, last_seq=0L)
  let mismatched : @protocol.BoardSnapshot = { ..frame, board_revision: 5L, }
  assert_true(replica.apply_snapshot(mismatched) is @client.NeedsSnapshot(_))
  assert_false(replica.has_snapshot())
}

///|
test "getters return deeply detached records" {
  let replica = seeded()
  let tasks = replica.tasks()
  tasks[0].definition_of_done.push("mutated")
  tasks[0].dependencies.push("mutated")
  tasks.clear()
  assert_eq_eq(replica.tasks().length(), 1)
  assert_eq_eq(replica.tasks()[0].id, "t1")
  assert_eq_eq(replica.tasks()[0].definition_of_done, ["unit tests"])
  assert_eq_eq(replica.tasks()[0].dependencies, [])
  let attempts = replica.attempts()
  attempts.clear()
  assert_eq_eq(replica.attempts().length(), 1)
  assert_eq_eq(replica.attempts()[0].id, "a1")
}

///|
test "applied event payloads are copied, so input mutation cannot leak in" {
  let replica = seeded()
  let task = wire_task(id="mut")
  let event = task_event(seq=2L, revision=2L, task~, task_id="mut")
  assert_eq_eq(replica.apply_event(event), @client.Applied)
  guard task is Json::Object(fields) else { abort("object") }
  guard fields.get("definition_of_done") is Some(Json::Array(dod)) else {
    abort("array")
  }
  dod.push("mutated")
  fields["stage"] = Json::string("suspended")
  guard event.payload is Json::Object(payload_fields) else { abort("object") }
  payload_fields["task_id"] = Json::string("hijack")
  guard replica.tasks().search_by(t => t.id == "mut") is Some(index) else {
    abort("record")
  }
  let record = replica.tasks()[index]
  assert_eq_eq(record.stage, @client.Created)
  assert_eq_eq(record.definition_of_done, ["unit tests"])
  assert_eq_eq(record.id, "mut")
}

///|
test "snapshot input json is not aliased into the replica" {
  let replica = @client.BoardReplica::empty()
  let task = wire_task(id="t1")
  let frame = snapshot_frame(revision=1L, last_seq=0L, tasks=[task])
  assert_eq_eq(replica.apply_snapshot(frame), @client.Applied)
  guard task is Json::Object(fields) else { abort("object") }
  fields["stage"] = Json::string("done")
  guard frame.payload is Json::Object(payload) else { abort("object") }
  guard payload.get("board") is Some(Json::Object(board)) else {
    abort("board")
  }
  board["revision"] = Json::number(99)
  assert_eq_eq(replica.revision(), 1L)
  assert_eq_eq(replica.tasks()[0].stage, @client.Created)
}

///|
test "copy is an equal deep clone that can be updated independently" {
  let replica = seeded()
  let copy = replica.copy()
  assert_eq_eq(copy, replica)
  assert_eq_eq(
    copy.apply_event(
      task_event(seq=2L, revision=1L, task=wire_task(id="t2"), task_id="t2"),
    ),
    @client.Applied,
  )
  assert_eq_eq(copy.revision(), 1L)
  assert_eq_eq(copy.last_seq(), 2L)
  assert_eq_eq(copy.tasks().length(), 2)
  assert_eq_eq(replica.last_seq(), 1L)
  assert_eq_eq(replica.tasks().length(), 1)
  assert_false(copy == replica)
  assert_true(copy != replica)
  assert_eq_eq(replica.copy(), replica)
  assert_eq_eq(replica.copy().copy(), replica)
}

///|
test "copy records are detached from the original's records" {
  let replica = seeded()
  let copy = replica.copy()
  let view = copy.tasks()
  view[0].definition_of_done.push("mutated")
  view.clear()
  assert_eq_eq(copy.tasks()[0].definition_of_done, ["unit tests"])
  assert_eq_eq(copy.tasks().length(), 1)
  assert_eq_eq(replica.tasks()[0].definition_of_done, ["unit tests"])
  assert_eq_eq(copy, replica)
  assert_eq_eq(replica.copy(), replica)
}

///|
test "task model decodes a pinned selection and accepts the model event" {
  let replica = @client.BoardReplica::empty()
  let task = wire_task(
    model=Json::object({
      "slot": Json::string("openai/gpt-5.2"),
      "effort": Json::string("high"),
    }),
  )
  let frame = snapshot_frame(revision=1L, last_seq=0L, tasks=[task])
  assert_eq_eq(replica.apply_snapshot(frame), @client.Applied)
  assert_eq_eq(
    replica.tasks()[0].model,
    Some(
      @client.ClientModelSelection::ClientModelSelection(
        slot="openai/gpt-5.2",
        effort=Some("high"),
      ),
    ),
  )
  let changed = task_event(
    seq=1L,
    revision=1L,
    kind="board.task.model_changed",
    task~,
    task_id="t1",
  )
  assert_eq_eq(replica.apply_event(changed), @client.Applied)
  assert_eq_eq(replica.tasks()[0].model.unwrap().slot, "openai/gpt-5.2")
}

///|
fn wire_verification(
  kind~ : String = "command",
  result~ : String = "passed",
) -> Json {
  Json::object({
    "kind": Json::string(kind),
    "label": Json::string("moon test src/client"),
    "result": Json::string(result),
    "detail": Json::string("69 tests"),
  })
}

///|
fn wire_artifact(kind~ : String = "file") -> Json {
  Json::object({
    "kind": Json::string(kind),
    "label": Json::string("client.mbt"),
    "uri_or_digest": Json::string("src/client/client.mbt"),
  })
}

///|
fn wire_review(
  verification~ : Array[Json] = [wire_verification()],
  artifacts~ : Array[Json] = [wire_artifact()],
) -> Json {
  Json::object({
    "outcome": Json::string("Review shows the curated handoff."),
    "summary": Json::string("Adds a durable review report read model."),
    "changes": Json::array([
      Json::string("Task wire carries review."),
      Json::string("Legacy is null."),
    ]),
    "verification": Json::array(verification),
    "risks": Json::array([Json::string("Evidence is worker-derived.")]),
    "notes": Json::array([Json::string("Order is preserved verbatim.")]),
    "open_questions": Json::array([Json::string("Does a retry keep it?")]),
    "artifacts": Json::array(artifacts),
  })
}

///|
test "task review decodes nested evidence and artifacts" {
  let replica = @client.BoardReplica::empty()
  let task = wire_task(
    review=wire_review(
      verification=[
        wire_verification(),
        wire_verification(kind="manual", result="not_run"),
        wire_verification(kind="artifact", result="unknown"),
      ],
      artifacts=[wire_artifact(), wire_artifact(kind="screenshot")],
    ),
  )
  let frame = snapshot_frame(revision=1L, last_seq=0L, tasks=[task])
  assert_eq_eq(replica.apply_snapshot(frame), @client.Applied)
  assert_eq_eq(
    replica.tasks()[0].review,
    Some(
      @client.ClientReviewReport::ClientReviewReport(
        outcome="Review shows the curated handoff.",
        summary="Adds a durable review report read model.",
        changes=["Task wire carries review.", "Legacy is null."],
        verification=[
          @client.ClientReviewEvidence::ClientReviewEvidence(
            kind=@client.ClientReviewEvidenceKind::Command,
            label="moon test src/client",
            result=@client.ClientReviewEvidenceResult::Passed,
            detail="69 tests",
          ),
          @client.ClientReviewEvidence::ClientReviewEvidence(
            kind=@client.ClientReviewEvidenceKind::Manual,
            label="moon test src/client",
            result=@client.ClientReviewEvidenceResult::NotRun,
            detail="69 tests",
          ),
          @client.ClientReviewEvidence::ClientReviewEvidence(
            kind=@client.ClientReviewEvidenceKind::Artifact,
            label="moon test src/client",
            result=@client.ClientReviewEvidenceResult::Unknown,
            detail="69 tests",
          ),
        ],
        risks=["Evidence is worker-derived."],
        notes=["Order is preserved verbatim."],
        open_questions=["Does a retry keep it?"],
        artifacts=[
          @client.ClientReviewArtifact::ClientReviewArtifact(
            kind=@client.ClientReviewArtifactKind::File,
            label="client.mbt",
            uri_or_digest="src/client/client.mbt",
          ),
          @client.ClientReviewArtifact::ClientReviewArtifact(
            kind=@client.ClientReviewArtifactKind::Screenshot,
            label="client.mbt",
            uri_or_digest="src/client/client.mbt",
          ),
        ],
      ),
    ),
  )
}

///|
test "task review is none for a null or an absent field" {
  let replica = @client.BoardReplica::empty()
  assert_eq_eq(
    replica.apply_snapshot(
      snapshot_frame(revision=1L, last_seq=0L, tasks=[
        wire_task(review=Json::null()),
      ]),
    ),
    @client.Applied,
  )
  assert_eq_eq(replica.tasks()[0].review, None)
  let absent = wire_task()
  guard absent is Json::Object(fields) else { abort("object") }
  ignore(fields.remove("review"))
  assert_eq_eq(
    replica.apply_snapshot(
      snapshot_frame(revision=1L, last_seq=0L, tasks=[absent]),
    ),
    @client.Applied,
  )
  assert_eq_eq(replica.tasks()[0].review, None)
}

///|
test "task review records must be complete and strictly typed" {
  let replica = @client.BoardReplica::empty()
  let no_review = wire_review()
  guard no_review is Json::Object(review_fields) else { abort("object") }
  ignore(review_fields.remove("open_questions"))
  let missing_evidence_field = wire_review()
  guard missing_evidence_field is Json::Object(evidence_outer) else {
    abort("object")
  }
  guard evidence_outer["verification"] is Json::Array(evidence_entries) else {
    abort("array")
  }
  guard evidence_entries[0] is Json::Object(evidence_fields) else {
    abort("object")
  }
  ignore(evidence_fields.remove("detail"))
  let unknown_artifact = wire_review()
  guard unknown_artifact is Json::Object(artifact_outer) else {
    abort("object")
  }
  guard artifact_outer["artifacts"] is Json::Array(artifact_entries) else {
    abort("array")
  }
  guard artifact_entries[0] is Json::Object(artifact_fields) else {
    abort("object")
  }
  artifact_fields["kind"] = Json::string("photo")
  let invalid_reviews : Array[Json] = [
    no_review,
    missing_evidence_field,
    unknown_artifact,
    wire_review(verification=[wire_verification(kind="shell")]),
    wire_review(verification=[wire_verification(result="maybe")]),
    wire_review(verification=[Json::string("command")]),
    wire_review(artifacts=[Json::string("src/client/client.mbt")]),
  ]
  for review in invalid_reviews {
    let frame = snapshot_frame(revision=1L, last_seq=0L, tasks=[
      wire_task(review~),
    ])
    assert_true(replica.apply_snapshot(frame) is @client.NeedsSnapshot(_))
    assert_false(replica.has_snapshot())
  }
}

///|
test "review report set event decodes the committed task review" {
  let replica = @client.BoardReplica::empty()
  let task = wire_task(stage="review", review=wire_review())
  let frame = snapshot_frame(revision=1L, last_seq=0L, tasks=[task])
  assert_eq_eq(replica.apply_snapshot(frame), @client.Applied)
  assert_true(replica.tasks()[0].review is Some(_))
  let event = task_event(
    seq=1L,
    revision=1L,
    kind="board.task.review_report_set",
    task~,
    task_id="t1",
  )
  assert_eq_eq(replica.apply_event(event), @client.Applied)
  assert_true(replica.tasks()[0].review is Some(_))
  // A clear arrives as the same kind with the committed task carrying null.
  let cleared = task_event(
    seq=2L,
    revision=2L,
    kind="board.task.review_report_set",
    task=wire_task(stage="running", review=Json::null()),
    task_id="t1",
  )
  assert_eq_eq(replica.apply_event(cleared), @client.Applied)
  assert_eq_eq(replica.tasks()[0].review, None)
  assert_eq_eq(replica.tasks()[0].stage, @client.Running)
}

///|
test "snapshot decodes review feedback and treats the key as additive" {
  let frame = snapshot_frame(revision=2L, last_seq=0L, tasks=[
    wire_task(
      id="t1",
      stage="ready",
      ready=Json::number(9000),
      review_feedback=Json::string("Add the missing regression test."),
    ),
    wire_task(id="t2", stage="ready"),
  ])
  guard @client.decode_board_snapshot(frame) is Ok(decoded) else {
    abort("expected a valid snapshot")
  }
  assert_eq_eq(
    decoded.tasks[0].review_feedback,
    Some("Add the missing regression test."),
  )
  assert_eq_eq(decoded.tasks[1].review_feedback, None)
  // A task record written before the field existed still decodes as None.
  let legacy = wire_task(id="t3")
  guard legacy is Json::Object(legacy_fields) else { abort("object") }
  ignore(legacy_fields.remove("review_feedback"))
  let frame = snapshot_frame(revision=2L, last_seq=0L, tasks=[legacy])
  guard @client.decode_board_snapshot(frame) is Ok(decoded) else {
    abort("expected a valid snapshot")
  }
  assert_eq_eq(decoded.tasks[0].review_feedback, None)
  // A non-string body is a decode failure, never a silent None.
  let frame = snapshot_frame(revision=2L, last_seq=0L, tasks=[
    wire_task(id="t4", review_feedback=Json::number(1)),
  ])
  assert_eq_eq(
    @client.decode_board_snapshot(frame),
    Err(@client.InvalidData("expected string")),
  )
}

///|
/// The one wire event that changes a ticket and its attempt together.
fn request_changes_payload(
  task~ : Json = wire_task(
    stage="ready",
    ready=Json::number(9000),
    review_feedback=Json::string("Add the missing regression test."),
  ),
  attempt~ : Json = wire_attempt(
    kind="review",
    status="running",
    review=Json::string("changes_requested"),
    started=Json::number(8000),
  ),
  feedback~ : String = "Add the missing regression test.",
) -> Json {
  Json::object({
    "task_id": Json::string("t1"),
    "task": task,
    "attempt_id": Json::string("a1"),
    "attempt": attempt,
    "feedback": Json::string(feedback),
    "at_ms": Json::number(9000),
  })
}

///|
test "review changes requested event projects the ticket and the attempt" {
  let replica = seeded()
  assert_eq_eq(
    replica.apply_event({
      seq: 2L,
      board_revision: 2L,
      kind: "board.task.review_changes_requested",
      scope: None,
      payload: request_changes_payload(),
    }),
    @client.Applied,
  )
  assert_eq_eq(replica.revision(), 2L)
  assert_eq_eq(replica.last_seq(), 2L)
  let task = replica.tasks()[0]
  assert_eq_eq(task.stage, @client.Ready)
  assert_eq_eq(task.ready_since_ms, Some(9000L))
  assert_eq_eq(task.review_feedback, Some("Add the missing regression test."))
  // The decision lands on the attempt in the same revision.
  let attempt = replica.attempts()[0]
  assert_eq_eq(attempt.status, @client.Running)
  assert_eq_eq(attempt.review, Some(@client.ChangesRequested))
  assert_eq_eq(attempt.finished_at_ms, None)
  // Every derived value is cross-checked: a ticket that is not Ready, or a
  // body that disagrees with the task, invalidates instead of misprojecting.
  let not_ready = seeded()
  assert_eq_eq(
    not_ready.apply_event({
      seq: 2L,
      board_revision: 2L,
      kind: "board.task.review_changes_requested",
      scope: None,
      payload: request_changes_payload(
        task=wire_task(
          stage="review",
          review_feedback=Json::string("Add the missing regression test."),
        ),
      ),
    }),
    @client.NeedsSnapshot("request-changes metadata mismatch"),
  )
  let disagreeing = seeded()
  assert_eq_eq(
    disagreeing.apply_event({
      seq: 2L,
      board_revision: 2L,
      kind: "board.task.review_changes_requested",
      scope: None,
      payload: request_changes_payload(
        task=wire_task(
          stage="ready",
          review_feedback=Json::string("Something else entirely."),
        ),
      ),
    }),
    @client.NeedsSnapshot("request-changes metadata mismatch"),
  )
  let wrong_attempt = seeded()
  assert_eq_eq(
    wrong_attempt.apply_event({
      seq: 2L,
      board_revision: 2L,
      kind: "board.task.review_changes_requested",
      scope: None,
      payload: request_changes_payload(
        attempt=wire_attempt(
          id="a2",
          kind="review",
          status="running",
          review=Json::string("changes_requested"),
        ),
      ),
    }),
    @client.NeedsSnapshot("request-changes metadata mismatch"),
  )
}
