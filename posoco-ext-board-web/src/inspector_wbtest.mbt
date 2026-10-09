///|
fn dependency_task_json(id : String, dependencies : Array[String]) -> Json {
  {
    "id": id.to_json(),
    "title": ("Title " + id).to_json(),
    "description": "Task details",
    "stage": "ready",
    "priority": "high",
    "definition_of_done": ["Tests pass"],
    "dependencies": dependencies.to_json(),
    "created_at_ms": 10,
    "updated_at_ms": 20,
    "ready_since_ms": 11,
  }
}

///|
fn inspector_snapshot(
  tasks : Array[Json],
  attempts? : Array[Json] = [],
  revision? : Int64 = 1L,
) -> String {
  @protocol.encode_server_frame(
    Snapshot({
      protocol_version: 1,
      last_seq: 0L,
      board_revision: revision,
      payload: {
        "board": {
          "revision": revision.to_double().to_json(),
          "tasks": tasks.to_json(),
          "attempts": attempts.to_json(),
        },
        "events": [],
      },
    }),
  )
}

///|
fn inspector_model() -> Model {
  let replica = @client.BoardReplica::empty()
  guard replica.apply_text(
      inspector_snapshot([
        dependency_task_json("t", ["a"]),
        dependency_task_json("a", []),
        dependency_task_json("b", []),
      ]),
    )
    is Applied else {
    abort("Invalid inspector test snapshot")
  }
  { ..Model::empty(true), replica, connection: Online, }
}

///|
fn dependency_event(
  dependencies : Array[String],
  seq? : Int64 = 1L,
  revision? : Int64 = 2L,
) -> String {
  @protocol.encode_server_frame(
    Event({
      seq,
      board_revision: revision,
      kind: "board.task.dependencies_changed",
      scope: None,
      payload: {
        "task_id": "t",
        "task": dependency_task_json("t", dependencies),
      },
    }),
  )
}

///|
fn draft_model() -> Model {
  let (selected, _) = update(
    inspector_model(),
    TaskSelected("t"),
    test_emit,
    test_env(),
  )
  let (opened, _) = update(selected, DependenciesOpened, test_emit, test_env())
  opened
}

///|
test "task selection switches and dismisses without copying or mutating entities" {
  let original = inspector_model()
  let (selected, command) = update(
    original,
    TaskSelected("t"),
    test_emit,
    test_env(),
  )
  assert_eq(selected.selected_task, Some("t"))
  assert_eq(inspector_task(selected).unwrap().title, "Title t")
  assert_true(selected.replica == original.replica)
  debug_inspect(command, content="[]")
  let (switched, _) = update(selected, TaskSelected("b"), test_emit, test_env())
  assert_eq(switched.selected_task, Some("b"))
  assert_eq(inspector_task(switched).unwrap().id, "b")
  let (closed, _) = update(switched, InspectorClosed, test_emit, test_env())
  assert_true(closed.selected_task is None)
  assert_true(inspector_task(closed) is None)
  assert_true(closed.replica == original.replica)
  let (invalid, _) = update(
    closed,
    TaskSelected("missing"),
    test_emit,
    test_env(),
  )
  assert_true(invalid == closed)
}

///|
test "resync hides all inspector data and revalidates ids against authoritative replacement" {
  let original = draft_model()
  let resync = @protocol.encode_server_frame(
    ResyncRequired(reason="test", current_seq=1L),
  )
  let (stale, _) = update(
    original,
    SocketEvent(0, Message(resync)),
    test_emit,
    test_env(),
  )
  assert_eq(stale.selected_task, Some("t"))
  assert_true(stale.dependency_editor == original.dependency_editor)
  assert_true(inspector_task(stale) is None)
  assert_eq(inspector_attempts(stale).length(), 0)
  assert_eq(dependency_candidates(stale, "t").length(), 0)
  let (retrying, _) = update(stale, Retry(0), test_emit, test_env())
  let (missing, _) = update(
    retrying,
    SocketEvent(
      1,
      Message(inspector_snapshot([dependency_task_json("b", [])], revision=2L)),
    ),
    test_emit,
    test_env(),
  )
  assert_true(missing.selected_task is None)
  assert_true(missing.dependency_editor is None)
  assert_true(missing.notice is Some({ severity: Warning, .. }))
}

///|
test "inspector attempt history is a live detached selection from the replica" {
  let attempt : Json = {
    "id": "attempt-1",
    "task_id": "t",
    "kind": "review",
    "status": "succeeded",
    "review": "approved",
    "created_at_ms": 12,
    "started_at_ms": 13,
    "finished_at_ms": 18,
    "updated_at_ms": 18,
  }
  let other : Json = {
    "id": "attempt-2",
    "task_id": "b",
    "kind": "execute",
    "status": "queued",
    "review": null,
    "created_at_ms": 19,
    "started_at_ms": null,
    "finished_at_ms": null,
    "updated_at_ms": 19,
  }
  let (selected, _) = update(
    inspector_model(),
    TaskSelected("t"),
    test_emit,
    test_env(),
  )
  let (populated, _) = update(
    selected,
    SocketEvent(
      0,
      Message(
        inspector_snapshot(
          [
            dependency_task_json("t", ["a"]),
            dependency_task_json("a", []),
            dependency_task_json("b", []),
          ],
          attempts=[attempt, other],
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  let attempts = inspector_attempts(populated)
  assert_eq(attempts.length(), 1)
  assert_eq(attempts[0].id, "attempt-1")
  assert_true(attempts[0].kind is Review)
  assert_true(attempts[0].status is Succeeded)
  assert_true(attempts[0].review is Some(Approved))
  assert_eq(attempts[0].finished_at_ms, Some(18L))
  attempts.clear()
  assert_eq(inspector_attempts(populated).length(), 1)
  let (switched, _) = update(
    populated,
    TaskSelected("b"),
    test_emit,
    test_env(),
  )
  assert_eq(inspector_attempts(switched)[0].id, "attempt-2")
  assert_true(inspector_attempts(switched)[0].review is None)
}

///|
test "inspector derives incremental attempt history and current title rather than caching entities" {
  let model = draft_model()
  let attempt : Json = {
    "id": "attempt-1",
    "task_id": "t",
    "kind": "execute",
    "status": "running",
    "review": null,
    "created_at_ms": 21,
    "started_at_ms": 22,
    "finished_at_ms": null,
    "updated_at_ms": 22,
  }
  let event = @protocol.encode_server_frame(
    Event({
      seq: 1L,
      board_revision: 2L,
      kind: "board.attempt.started",
      scope: None,
      payload: { "attempt_id": "attempt-1", "task_id": "t", "attempt": attempt },
    }),
  )
  let (started, _) = update(
    model,
    SocketEvent(0, Message(event)),
    test_emit,
    test_env(),
  )
  assert_eq(inspector_attempts(started).length(), 1)
  assert_true(inspector_attempts(started)[0].status is Running)
  let task = dependency_task_json("t", ["a"])
  guard task is Object(fields) else { abort("Expected test task object") }
  fields.set("title", "Updated authoritative title")
  let event = @protocol.encode_server_frame(
    Event({
      seq: 2L,
      board_revision: 3L,
      kind: "board.task.updated",
      scope: None,
      payload: { "task_id": "t", "task": task },
    }),
  )
  let (updated, _) = update(
    started,
    SocketEvent(0, Message(event)),
    test_emit,
    test_env(),
  )
  assert_eq(
    inspector_task(updated).unwrap().title,
    "Updated authoritative title",
  )
  assert_eq(inspector_task(model).unwrap().title, "Title t")
  assert_true(updated.dependency_editor == model.dependency_editor)
  assert_false(dependency_conflict(updated, updated.dependency_editor.unwrap()))
}

///|
test "dependency draft owns independent arrays and never projects local changes" {
  let model = draft_model()
  let draft = model.dependency_editor.unwrap()
  assert_eq(draft.base_dependencies, ["a"])
  assert_eq(draft.dependencies, ["a"])
  let task = inspector_task(model).unwrap()
  task.dependencies.push("outside")
  assert_eq(draft.dependencies, ["a"])
  draft.dependencies.push("b")
  assert_eq(draft.base_dependencies, ["a"])
  assert_eq(inspector_task(model).unwrap().dependencies, ["a"])
  let candidates = dependency_candidates(model, "t")
  assert_eq(candidates.length(), 2)
  assert_false(candidates.any(task => task.id == "t"))
}

///|
test "queued checkbox changes toggle current draft rather than captured render state" {
  let original = draft_model()
  let (added, _) = update(
    original,
    DependencySelectionChanged("b"),
    test_emit,
    test_env(),
  )
  assert_eq(added.dependency_editor.unwrap().dependencies, ["a", "b"])
  let (removed, _) = update(
    added,
    DependencySelectionChanged("b"),
    test_emit,
    test_env(),
  )
  assert_eq(removed.dependency_editor.unwrap().dependencies, ["a"])
  assert_true(removed.replica == original.replica)
  let (submitted, _) = update(
    added,
    DependenciesSubmitted,
    test_emit,
    test_env(),
  )
  let (blocked, command) = update(
    submitted,
    DependencySelectionChanged("b"),
    test_emit,
    test_env(),
  )
  assert_true(blocked == submitted)
  debug_inspect(command, content="[]")
}

///|
test "dependency toggle guards self duplicates and missing candidates but permits explicit removal" {
  let model = draft_model()
  let (added, _) = update(
    model,
    DependencyToggled("b", true),
    test_emit,
    test_env(),
  )
  assert_eq(added.dependency_editor.unwrap().dependencies, ["a", "b"])
  assert_eq(model.dependency_editor.unwrap().dependencies, ["a"])
  for id in ["t", "a", "b", "missing"] {
    let (blocked, command) = update(
      added,
      DependencyToggled(id, true),
      test_emit,
      test_env(),
    )
    assert_true(blocked == added)
    debug_inspect(command, content="[]")
  }
  let (removed, _) = update(
    added,
    DependencyToggled("a", false),
    test_emit,
    test_env(),
  )
  assert_eq(removed.dependency_editor.unwrap().dependencies, ["b"])
  let (cleared, command) = update(
    removed,
    DependenciesCleared,
    test_emit,
    test_env(),
  )
  assert_eq(cleared.dependency_editor.unwrap().dependencies, [])
  assert_eq(inspector_task(cleared).unwrap().dependencies, ["a"])
  debug_inspect(command, content="[]")
}

///|
test "draft survives inspector switch and dismissal until explicit cancellation" {
  let model = draft_model()
  let (other, _) = update(model, TaskSelected("b"), test_emit, test_env())
  assert_eq(inspector_task(other).unwrap().id, "b")
  assert_true(other.dependency_editor == model.dependency_editor)
  let (blocked, _) = update(other, DependenciesOpened, test_emit, test_env())
  assert_true(blocked == other)
  let (closed, _) = update(other, InspectorClosed, test_emit, test_env())
  assert_true(closed.selected_task is None)
  assert_true(closed.dependency_editor == model.dependency_editor)
  let (returned, _) = update(
    closed,
    DependencyDraftReturned,
    test_emit,
    test_env(),
  )
  assert_eq(returned.selected_task, Some("t"))
  let (cancelled, _) = update(
    returned,
    DependenciesCancelled,
    test_emit,
    test_env(),
  )
  assert_true(cancelled.dependency_editor is None)
  assert_true(cancelled.replica == model.replica)
}
