///|
/// S3B2B2 native WebSocket E2E: real loopback sockets drive the command
/// handler the runtime installs before bind, against the durable
/// coordinator over memory and failure-injecting stores.

///|
/// Send one wire Command frame.
async fn board_native_command(
  ws : @websocket.Conn,
  command_id : String,
  name : String,
  expected_revision : Int64,
  args : Json,
) -> Unit {
  ws.send_text(
    @protocol.encode_client_frame(
      @protocol.Command({ command_id, name, expected_revision, args, }),
    ),
  )
}

///|
/// The next frame must be the correlated command result.
async fn board_native_result(
  ws : @websocket.Conn,
  command_id : String,
) -> @protocol.BoardCommandResult {
  guard board_test_frame(ws) is CommandResult(result) else {
    fail("expected a command result for \{command_id}")
  }
  assert_eq(result.command_id, command_id)
  result
}

///|
/// The server-owned command time every committed payload carries.
fn board_native_at_ms(payload : Json) -> Double raise {
  guard payload is Json::Object(fields) else {
    fail("expected an object payload")
  }
  guard fields.get("at_ms") is Some(Number(value, ..)) else {
    fail("expected the at_ms stamp")
  }
  value
}

///|
/// Standard create payload; the server owns `at_ms`, so it is never sent.
fn board_native_create_args(id : String) -> Json {
  {
    "id": id,
    "title": "task \{id}",
    "description": "",
    "priority": "normal",
    "definition_of_done": [],
    "dependencies": [],
  }
}

///|
/// Ready, bound runtime over an explicit store, wired to a real native
/// server and shared hub through the adapter constructor.
async fn board_native_runtime_store(
  group : @async.TaskGroup[Unit],
  store~ : &@store.BoardStore,
  now_ms~ : () -> Int64,
) -> BoardRuntime {
  let hub = BoardEventHub()
  let server = NativeBoardWebServer(hub~)
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(
    hub~,
    server~,
    opener~,
    store~,
    now_ms~,
  )
  runtime.attach(group)
  assert_true(runtime.coordinator.wait_ready() is Ok(_))
  assert_true(runtime.ensure_server() is Ok(_))
  runtime
}

///|
/// Memory-backed variant of `board_native_runtime_store`.
async fn board_native_runtime(
  group : @async.TaskGroup[Unit],
  now_ms~ : () -> Int64,
) -> BoardRuntime {
  let store : &@store.BoardStore = @store.MemoryBoardStore::MemoryBoardStore()
  board_native_runtime_store(group, store~, now_ms~)
}

///|
/// Authenticated live WebSocket URL of the bound runtime server.
fn board_native_url(runtime : BoardRuntime) -> String raise {
  guard runtime.status() is Running(endpoint) else {
    fail("native board server is not running")
  }
  let token = board_query_param(runtime.server.browser_url().unwrap(), "token").unwrap()
  endpoint.ws_url() + "?token=" + token
}

///|
/// Failure-injecting store in the style of the durable coordinator tests:
/// deterministic counters instead of timing. An uncertain persist leaves
/// the attempted snapshot reloadable, modelling a write that crossed the
/// visibility boundary before the error surfaced.
priv struct CommandScriptStore {
  /// Remaining pre-visibility persist failures.
  mut fail_persists : Int
  /// Remaining persists that report uncertain durability.
  mut uncertain_persists : Int
  /// Snapshot of a persist that may have landed despite the error.
  mut landed : @domain.BoardStateSnapshot?
  mut durable : @domain.BoardStateSnapshot
  journal : Array[@store.JournalRecord]
  mut persist_attempts : Int
}

///|
fn CommandScriptStore::CommandScriptStore() -> CommandScriptStore {
  {
    fail_persists: 0,
    uncertain_persists: 0,
    landed: None,
    durable: @store.empty_snapshot(),
    journal: [],
    persist_attempts: 0,
  }
}

///|
impl @store.BoardStore for CommandScriptStore with fn load(self) {
  let snapshot = match self.landed {
    Some(snapshot) => snapshot
    None => self.durable
  }
  Ok({ snapshot: snapshot.copy_detached(), journal: self.journal.copy(), })
}

///|
impl @store.BoardStore for CommandScriptStore with fn persist(
  self,
  snapshot,
  events,
) {
  self.persist_attempts = self.persist_attempts + 1
  if self.fail_persists > 0 {
    self.fail_persists = self.fail_persists - 1
    return Err(@store.Injected(@store.TempWrite))
  }
  if self.uncertain_persists > 0 {
    self.uncertain_persists = self.uncertain_persists - 1
    self.landed = Some(snapshot.copy_detached())
    return Err(@store.DurabilityUncertain("injected directory fsync loss"))
  }
  self.landed = None
  self.durable = snapshot.copy_detached()
  for event in events {
    self.journal.push({ schema_version: 1, revision: snapshot.revision, event, })
  }
  Ok(())
}

///|
async test "native create stamps deterministic server time and answers event then result" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let runtime = board_native_runtime(group, now_ms=() => 1234L)
      let url = board_native_url(runtime)
      let ws = @websocket.connect(url)
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(runtime.hub, 1)
      board_native_command(
        ws,
        "create-1",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      // The committed event streams before the correlated result, and the
      // result itself never enters hub history.
      guard board_test_frame(ws) is Event(event) else {
        fail("expected the created event before the result")
      }
      assert_eq(event.seq, 1L)
      assert_eq(event.board_revision, 1L)
      assert_eq(event.kind, "board.task.created")
      assert_eq(event.scope, None)
      assert_eq(event.payload, {
        "task_id": "t1",
        "task": {
          "id": "t1",
          "title": "task t1",
          "description": "",
          "stage": "created",
          "priority": "normal",
          "definition_of_done": [],
          "dependencies": [],
          "created_at_ms": Json::number(1234),
          "updated_at_ms": Json::number(1234),
          "ready_since_ms": Json::null(),
        },
        "at_ms": Json::number(1234),
      })
      assert_eq(
        board_test_frame(ws),
        @protocol.CommandResult({
          command_id: "create-1",
          accepted: true,
          error: None,
          current_revision: Some(1L),
        }),
      )
      assert_eq(runtime.event_history(), [event])
      ws.close()
      board_wait_clients(runtime.hub, 0)
      // A fresh connection bootstraps from the durable baseline.
      let fresh = @websocket.connect(url)
      defer fresh.close()
      board_test_hello(fresh, 0L)
      guard board_test_frame(fresh) is Snapshot(snapshot) else {
        fail("a fresh connection requires the durable snapshot")
      }
      assert_eq(snapshot.protocol_version, @protocol.protocol_version())
      assert_eq(snapshot.last_seq, 1L)
      assert_eq(snapshot.board_revision, 1L)
      assert_eq(snapshot.payload, {
        "board": {
          "revision": Json::number(1),
          "tasks": [
            {
              "id": "t1",
              "title": "task t1",
              "description": "",
              "stage": "created",
              "priority": "normal",
              "definition_of_done": [],
              "dependencies": [],
              "created_at_ms": Json::number(1234),
              "updated_at_ms": Json::number(1234),
              "ready_since_ms": Json::null(),
            },
          ],
          "attempts": [],
        },
        "events": [event.to_json()],
      })
      runtime.shutdown()
    })
  })
}

///|
async test "native command chain covers all eight names with ordered events" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let runtime = board_native_runtime(group, now_ms=() => 1234L)
      let ws = @websocket.connect(board_native_url(runtime))
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(runtime.hub, 1)
      let chain : Array[(String, String, Int64, Json, String)] = [
        (
          "chain-1",
          "board.task.create",
          0L,
          board_native_create_args("t1"),
          "board.task.created",
        ),
        (
          "chain-2",
          "board.task.update",
          1L,
          { "id": "t1", "title": "renamed t1" },
          "board.task.updated",
        ),
        (
          "chain-3",
          "board.task.set_dependencies",
          2L,
          { "id": "t1", "dependencies": [] },
          "board.task.dependencies_changed",
        ),
        (
          "chain-4",
          "board.task.move",
          3L,
          { "id": "t1", "to": "refining" },
          "board.task.stage_changed",
        ),
        (
          "chain-5",
          "board.attempt.queue",
          4L,
          { "id": "a1", "task_id": "t1", "kind": "review" },
          "board.attempt.queued",
        ),
        (
          "chain-6",
          "board.attempt.start",
          5L,
          { "id": "a1" },
          "board.attempt.started",
        ),
        (
          "chain-7",
          "board.review.record",
          6L,
          { "id": "a1", "decision": "approved" },
          "board.review.recorded",
        ),
        (
          "chain-8",
          "board.attempt.finish",
          7L,
          { "id": "a1", "outcome": "succeeded" },
          "board.attempt.finished",
        ),
      ]
      for i, entry in chain {
        let (command_id, name, revision, args, kind) = entry
        board_native_command(ws, command_id, name, revision, args)
        guard board_test_frame(ws) is Event(event) else {
          fail("expected the \{kind} event")
        }
        assert_eq(event.seq, (i + 1).to_int64())
        assert_eq(event.board_revision, (i + 1).to_int64())
        assert_eq(event.kind, kind)
        assert_eq(board_native_at_ms(event.payload), 1234.0)
        assert_eq(
          board_test_frame(ws),
          @protocol.CommandResult({
            command_id,
            accepted: true,
            error: None,
            current_revision: Some((i + 1).to_int64()),
          }),
        )
      }
      assert_eq(runtime.current_seq(), 8L)
      assert_eq(runtime.coordinator.revision(), Ok(8L))
      let task = runtime.coordinator
        .task(id=@domain.BoardTaskId::BoardTaskId("t1"))
        .unwrap()
        .unwrap()
      assert_eq(task.title, "renamed t1")
      assert_eq(task.stage, @domain.Refining)
      assert_eq(task.updated_at_ms, 1234L)
      let attempt = runtime.coordinator
        .attempt(id=@domain.AttemptId::AttemptId("a1"))
        .unwrap()
        .unwrap()
      assert_eq(attempt.status, @domain.Succeeded)
      assert_eq(attempt.review, Some(@domain.Approved))
      runtime.shutdown()
    })
  })
}

///|
async test "native two clients conflict then fresh revision retry succeeds" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let runtime = board_native_runtime(group, now_ms=() => 1234L)
      let url = board_native_url(runtime)
      let ws_a = @websocket.connect(url)
      defer ws_a.close()
      board_test_hello(ws_a, 0L, has_board_snapshot=true)
      let ws_b = @websocket.connect(url)
      defer ws_b.close()
      board_test_hello(ws_b, 0L, has_board_snapshot=true)
      board_wait_clients(runtime.hub, 2)
      board_native_command(
        ws_a,
        "a-create",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      guard board_test_frame(ws_a) is Event(created) else {
        fail("expected the created event")
      }
      assert_true(board_native_result(ws_a, "a-create").accepted)
      assert_eq(board_test_frame(ws_b), @protocol.Event(created))
      // Both clients chose revision zero. Only A's mutation may commit.
      board_native_command(
        ws_b,
        "b-create",
        "board.task.create",
        0L,
        board_native_create_args("t2"),
      )
      assert_eq(board_native_result(ws_b, "b-create"), {
        command_id: "b-create",
        accepted: false,
        error: Some("revision_conflict"),
        current_revision: Some(1L),
      })
      assert_eq(runtime.current_seq(), 1L)
      assert_eq(runtime.event_history(), [created])
      // A new command using the authoritative revision succeeds on B's socket.
      board_native_command(ws_b, "b-move-2", "board.task.move", 1L, {
        "id": "t1",
        "to": "refining",
      })
      guard board_test_frame(ws_b) is Event(retried) else {
        fail("expected the retry event")
      }
      assert_eq(retried.seq, 2L)
      assert_eq(retried.board_revision, 2L)
      assert_eq(board_native_result(ws_b, "b-move-2"), {
        command_id: "b-move-2",
        accepted: true,
        error: None,
        current_revision: Some(2L),
      })
      assert_eq(board_test_frame(ws_a), @protocol.Event(retried))
      assert_eq(runtime.coordinator.revision(), Ok(2L))
      let task = runtime.coordinator
        .task(id=@domain.BoardTaskId::BoardTaskId("t1"))
        .unwrap()
        .unwrap()
      assert_eq(task.stage, @domain.Refining)
      assert_eq(task.updated_at_ms, 1234L)
      runtime.shutdown()
    })
  })
}

///|
async test "native invalid commands answer and keep the socket alive" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let runtime = board_native_runtime(group, now_ms=() => 1234L)
      let ws = @websocket.connect(board_native_url(runtime))
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(runtime.hub, 1)
      board_native_command(ws, "bad-name", "board.task.destroy", 0L, {})
      assert_eq(board_native_result(ws, "bad-name"), {
        command_id: "bad-name",
        accepted: false,
        error: Some("invalid_command"),
        current_revision: Some(0L),
      })
      board_native_command(
        ws, "malformed", "board.task.create", 0L, "not an object",
      )
      assert_eq(board_native_result(ws, "malformed"), {
        command_id: "malformed",
        accepted: false,
        error: Some("invalid_arguments"),
        current_revision: Some(0L),
      })
      // A payload cannot smuggle the server-owned timestamp past the schema.
      board_native_command(ws, "smuggled-clock", "board.task.create", 0L, {
        "id": "t1",
        "title": "task t1",
        "description": "",
        "priority": "normal",
        "definition_of_done": [],
        "dependencies": [],
        "at_ms": Json::number(999999),
      })
      assert_eq(board_native_result(ws, "smuggled-clock"), {
        command_id: "smuggled-clock",
        accepted: false,
        error: Some("invalid_arguments"),
        current_revision: Some(0L),
      })
      // An empty correlation id is rejected but still answered.
      board_native_command(
        ws,
        "",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      assert_eq(board_native_result(ws, ""), {
        command_id: "",
        accepted: false,
        error: Some("invalid_command"),
        current_revision: Some(0L),
      })
      assert_eq(runtime.current_seq(), 0L)
      assert_eq(runtime.event_history(), [])
      assert_eq(runtime.coordinator.revision(), Ok(0L))
      // The same socket keeps serving valid commands.
      board_native_command(
        ws,
        "good-create",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      guard board_test_frame(ws) is Event(created) else {
        fail("expected the created event after the rejections")
      }
      assert_eq(created.seq, 1L)
      assert_true(board_native_result(ws, "good-create").accepted)
      assert_eq(runtime.current_seq(), 1L)
      runtime.shutdown()
    })
  })
}

///|
async test "native command_id correlates twice without deduplication" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let runtime = board_native_runtime(group, now_ms=() => 1234L)
      let ws = @websocket.connect(board_native_url(runtime))
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(runtime.hub, 1)
      board_native_command(
        ws,
        "same-id",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      guard board_test_frame(ws) is Event(first) else {
        fail("expected the first created event")
      }
      assert_eq(first.seq, 1L)
      assert_eq(board_native_result(ws, "same-id"), {
        command_id: "same-id",
        accepted: true,
        error: None,
        current_revision: Some(1L),
      })
      // The same correlation id commits again: it is not an idempotency key.
      board_native_command(
        ws,
        "same-id",
        "board.task.create",
        1L,
        board_native_create_args("t2"),
      )
      guard board_test_frame(ws) is Event(second) else {
        fail("expected the second created event")
      }
      assert_eq(second.seq, 2L)
      assert_eq(board_native_result(ws, "same-id"), {
        command_id: "same-id",
        accepted: true,
        error: None,
        current_revision: Some(2L),
      })
      assert_eq(runtime.coordinator.revision(), Ok(2L))
      assert_eq(runtime.coordinator.tasks().unwrap().length(), 2)
      runtime.shutdown()
    })
  })
}

///|
async test "native pre-visibility persistence failure mints no event and moves nothing" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let store = CommandScriptStore::CommandScriptStore()
      store.fail_persists = 1
      let runtime = board_native_runtime_store(group, store~, now_ms=() => 1234L)
      let ws = @websocket.connect(board_native_url(runtime))
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(runtime.hub, 1)
      board_native_command(
        ws,
        "doomed",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      // No event frame precedes the rejected result.
      assert_eq(board_native_result(ws, "doomed"), {
        command_id: "doomed",
        accepted: false,
        error: Some("persistence_failed"),
        current_revision: Some(0L),
      })
      assert_eq(runtime.current_seq(), 0L)
      assert_eq(runtime.event_history(), [])
      assert_eq(runtime.coordinator.revision(), Ok(0L))
      assert_eq(store.persist_attempts, 1)
      assert_eq(store.journal.length(), 0)
      // The coordinator stays ready: the retried write commits.
      board_native_command(
        ws,
        "retried",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      guard board_test_frame(ws) is Event(created) else {
        fail("expected the retried event")
      }
      assert_eq(created.seq, 1L)
      assert_true(board_native_result(ws, "retried").accepted)
      assert_eq(runtime.coordinator.revision(), Ok(1L))
      assert_eq(store.journal.length(), 1)
      runtime.shutdown()
    })
  })
}

///|
async test "native uncertain durability reloads the candidate then answers false with the new revision" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let store = CommandScriptStore::CommandScriptStore()
      store.uncertain_persists = 1
      let runtime = board_native_runtime_store(group, store~, now_ms=() => 1234L)
      let ws = @websocket.connect(board_native_url(runtime))
      defer ws.close()
      board_test_hello(ws, 0L, has_board_snapshot=true)
      board_wait_clients(runtime.hub, 1)
      board_native_command(
        ws,
        "uncertain",
        "board.task.create",
        0L,
        board_native_create_args("t1"),
      )
      // The reload found the candidate: it commits exactly once and its
      // event streams before the answer.
      guard board_test_frame(ws) is Event(event) else {
        fail("expected the reconciled candidate event")
      }
      assert_eq(event.seq, 1L)
      assert_eq(event.board_revision, 1L)
      assert_eq(event.kind, "board.task.created")
      assert_eq(board_native_result(ws, "uncertain"), {
        command_id: "uncertain",
        accepted: false,
        error: Some("durability_uncertain"),
        current_revision: Some(1L),
      })
      assert_eq(runtime.coordinator.revision(), Ok(1L))
      assert_eq(
        runtime.coordinator
        .task(id=@domain.BoardTaskId::BoardTaskId("t1"))
        .unwrap()
        .unwrap().created_at_ms,
        1234L,
      )
      assert_eq(runtime.current_seq(), 1L)
      assert_eq(store.persist_attempts, 1)
      runtime.shutdown()
    })
  })
}
