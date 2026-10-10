///|
fn filter_task_json(
  id : String,
  title : String,
  description : String,
  stage : String,
  priority : String,
  created_at_ms : Int,
) -> Json {
  {
    "id": id.to_json(),
    "title": title.to_json(),
    "description": description.to_json(),
    "stage": stage.to_json(),
    "priority": priority.to_json(),
    "definition_of_done": [],
    "dependencies": [],
    "created_at_ms": created_at_ms.to_json(),
    "updated_at_ms": created_at_ms.to_json(),
    "ready_since_ms": null,
  }
}

///|
fn filter_replica(tasks : Array[Json]) -> @client.BoardReplica {
  let replica = @client.BoardReplica::empty()
  guard replica.apply_text(inspector_snapshot(tasks)) is Applied else {
    abort("Invalid filter test snapshot")
  }
  replica
}

///|
fn filter_model(tasks : Array[Json]) -> Model {
  {
    ..Model::empty(true),
    replica: filter_replica(tasks),
    connection: Online,
    selected_task: Some("t1"),
  }
}

///|
fn sample_filter_tasks() -> Array[Json] {
  [
    filter_task_json(
      "t1", "Urgent Fix", "Payment edge case", "ready", "critical", 30,
    ),
    filter_task_json(
      "t2", "Routine chore", "Background sweep", "created", "low", 10,
    ),
    filter_task_json(
      "t3", "Unrelated", "Mentions t1 in prose", "review", "normal", 20,
    ),
  ]
}

///|
test "task filters match case-insensitively across title id and description" {
  let replica = filter_replica(sample_filter_tasks())
  let matches = (query : String) => {
    visible_tasks(replica, { ..TaskFilter::none(), query, }).map(task => task.id)
  }
  // Title, ID and description all match case-insensitively.
  assert_eq(matches("URGENT"), ["t1"])
  assert_eq(matches("urgent"), ["t1"])
  assert_eq(matches("T2"), ["t2"])
  assert_eq(matches("PAYMENT"), ["t1"])
  // The substring may live in another task's description.
  assert_eq(matches("t1 in prose"), ["t3"])
  // Whitespace-only and absent queries match everything.
  assert_eq(matches("").length(), 3)
  assert_eq(matches("   ").length(), 3)
  assert_eq(matches("no-such-task"), [])
}

///|
test "priority and stage filters combine with the text query" {
  let replica = filter_replica(sample_filter_tasks())
  let base = TaskFilter::none()
  assert_eq(
    visible_tasks(replica, { ..base, priority: Some(@client.Critical), }).map(task => {
      task.id
    }),
    ["t1"],
  )
  assert_eq(
    visible_tasks(replica, { ..base, stage: Some(@client.Review), }).map(task => {
      task.id
    }),
    ["t3"],
  )
  // Both structured filters and the query must hold at once.
  assert_eq(
    visible_tasks(replica, { ..base, query: "fix", stage: Some(@client.Ready), }).map(task => {
        task.id
      },
    ),
    ["t1"],
  )
  // No task carries the High priority.
  assert_eq(
    visible_tasks(replica, { ..base, priority: Some(@client.High), }).length(),
    0,
  )
  assert_eq(
    visible_tasks(replica, {
      query: "fix",
      priority: Some(@client.Low),
      stage: Some(@client.Ready),
    }).length(),
    0,
  )
}

///|
test "task order is deterministic created ascending with id ties" {
  let tasks = [
    filter_task_json("z", "Zed", "", "ready", "normal", 20),
    filter_task_json("b", "Bee", "", "ready", "normal", 10),
    filter_task_json("a", "Ay", "", "ready", "normal", 10),
    filter_task_json("c", "Cee", "", "ready", "normal", 30),
  ]
  let replica = filter_replica(tasks)
  let once = ordered_tasks(replica).map(task => task.id)
  // Insertion order is irrelevant and repeats agree; the 10/10 tie is broken
  // by the smaller ID first.
  assert_eq(once, ["a", "b", "z", "c"])
  assert_eq(once, ordered_tasks(replica).map(task => task.id))
  let lanes = visible_lane_tasks(replica, @client.Ready, TaskFilter::none())
  assert_eq(lanes.map(task => task.id), once)
}

///|
test "filters hide all is distinct from unknown and empty boards" {
  let filter = { ..TaskFilter::none(), query: "no-such-task", }
  // Unknown board: never claims a filter no-match.
  assert_false(filters_hide_all(@client.BoardReplica::empty(), filter))
  // Authoritative empty board: empty, not filtered.
  let empty = filter_replica([])
  assert_false(filters_hide_all(empty, filter))
  assert_false(filters_hide_all(empty, TaskFilter::none()))
  // Tasks exist and every one is hidden.
  let replica = filter_replica(sample_filter_tasks())
  assert_true(filters_hide_all(replica, filter))
  assert_false(filters_hide_all(replica, TaskFilter::none()))
  // A filter that keeps at least one task is not a no-match.
  assert_false(
    filters_hide_all(replica, { ..TaskFilter::none(), query: "fix", }),
  )
}

///|
test "filter changes never touch the selection drafts or the replica" {
  let original = draft_model()
  let hidden = { ..TaskFilter::none(), query: "zzz-hides-everything", }
  let (queried, command) = update(
    original,
    FilterQueryChanged(hidden.query),
    test_emit,
    test_env(),
  )
  debug_inspect(command, content="[]")
  assert_true(queried.task_filter == hidden)
  assert_eq(queried.selected_task, original.selected_task)
  assert_true(queried.dependency_editor == original.dependency_editor)
  assert_true(queried.editor == original.editor)
  assert_true(queried.attempt_draft == original.attempt_draft)
  assert_true(queried.finish_draft == original.finish_draft)
  assert_true(queried.review_draft == original.review_draft)
  assert_true(queried.replica == original.replica)
  assert_true(queried.connection is Online)
  // A hidden selection stays selected: the inspector is not filter-driven.
  assert_true(filters_hide_all(queried.replica, queried.task_filter))
  assert_eq(queried.selected_task, Some("t"))
  // Clearing resets only the filter.
  let (cleared, _) = update(queried, FiltersCleared, test_emit, test_env())
  assert_true(cleared.task_filter == TaskFilter::none())
  assert_eq(cleared.selected_task, original.selected_task)
  assert_true(cleared.dependency_editor == original.dependency_editor)
  assert_true(cleared.replica == original.replica)
}

///|
test "structured filter changes isolate drafts and the pending record" {
  // Finish and review drafts survive any filter change untouched.
  for model in [chosen_finish(), submitted_review()] {
    let (filtered, _) = update(
      model,
      FilterStageChanged("created"),
      test_emit,
      test_env(),
    )
    assert_true(filtered.finish_draft == model.finish_draft)
    assert_true(filtered.review_draft == model.review_draft)
    assert_eq(filtered.selected_task, model.selected_task)
    assert_true(filtered.pending == model.pending)
    assert_true(filtered.task_filter.stage == Some(@client.Created))
    let (cleared, _) = update(filtered, FiltersCleared, test_emit, test_env())
    assert_true(cleared.task_filter == TaskFilter::none())
    assert_true(cleared.finish_draft == model.finish_draft)
    assert_true(cleared.review_draft == model.review_draft)
  }
}

///|
test "filter select resolution clears on empty and keeps current on unknown" {
  let model = filter_model(sample_filter_tasks())
  let (prioritized, _) = update(
    model,
    FilterPriorityChanged("critical"),
    test_emit,
    test_env(),
  )
  assert_true(prioritized.task_filter.priority == Some(@client.Critical))
  let (stale_kept, _) = update(
    prioritized,
    FilterPriorityChanged("bogus"),
    test_emit,
    test_env(),
  )
  assert_true(stale_kept.task_filter.priority == Some(@client.Critical))
  let (priority_cleared, _) = update(
    stale_kept,
    FilterPriorityChanged(""),
    test_emit,
    test_env(),
  )
  assert_true(priority_cleared.task_filter.priority is None)
  let (staged, _) = update(
    priority_cleared,
    FilterStageChanged("suspended"),
    test_emit,
    test_env(),
  )
  assert_true(staged.task_filter.stage == Some(@client.Suspended))
  let (stage_kept, _) = update(
    staged,
    FilterStageChanged("not-a-stage"),
    test_emit,
    test_env(),
  )
  assert_true(stage_kept.task_filter.stage == Some(@client.Suspended))
  let (stage_cleared, _) = update(
    stage_kept,
    FilterStageChanged(""),
    test_emit,
    test_env(),
  )
  assert_true(stage_cleared.task_filter.stage is None)
}

///|
test "external membership updates respect the filter and selection isolation" {
  let model = {
    ..filter_model(sample_filter_tasks()),
    selected_task: Some("t2"),
  }
  let filtered = {
    ..model,
    task_filter: { ..TaskFilter::none(), query: "urgent", },
  }
  assert_eq(visible_tasks(filtered.replica, filtered.task_filter).length(), 1)
  // An external snapshot adding another matching task grows the visible set
  // without touching selection or drafts.
  let grown = [
    ..sample_filter_tasks(),
    filter_task_json("t4", "Urgent follow-up", "", "ready", "high", 40),
  ]
  let (updated, _) = update(
    filtered,
    SocketEvent(0, Message(inspector_snapshot(grown, revision=2L))),
    test_emit,
    test_env(),
  )
  assert_eq(visible_tasks(updated.replica, updated.task_filter).length(), 2)
  assert_eq(updated.replica.tasks().length(), 4)
  assert_eq(updated.selected_task, Some("t2"))
  // Removing the selected task externally still clears it through the
  // existing revalidation, filters or not.
  let (removed, _) = update(
    { ..filtered, selected_task: Some("t2"), },
    SocketEvent(
      0,
      Message(
        inspector_snapshot(
          [filter_task_json("t1", "Urgent Fix", "", "ready", "critical", 30)],
          revision=3L,
        ),
      ),
    ),
    test_emit,
    test_env(),
  )
  assert_true(removed.selected_task is None)
}

///|
test "count summaries report visible of total only while filtering" {
  let replica = filter_replica(sample_filter_tasks())
  assert_eq(task_count_summary(replica, TaskFilter::none()), "3 tasks")
  let filter = { ..TaskFilter::none(), query: "urgent", }
  assert_eq(task_count_summary(replica, filter), "1 of 3 tasks")
  assert_eq(lane_count_summary(replica, @client.Ready, TaskFilter::none()), "1")
  assert_eq(lane_count_summary(replica, @client.Ready, filter), "1 of 1")
  assert_eq(lane_count_summary(replica, @client.Created, filter), "0 of 1")
}
