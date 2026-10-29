///|
/// Fixtures for the worker progress updates carried inside `ticket_state`.
/// Updates are information only, so every fixture here is about what the inbox
/// shows and what the badge counts — never about a command.
fn progress_update(
  task_id : String,
  kind : String,
  message : String,
  at_ms : Int64,
) -> TicketProgress {
  { task_id, kind, message, at_ms, }
}

///|
fn progress_state(progress : Array[TicketProgress]) -> TicketState {
  {
    project: "",
    team: None,
    mcp_servers: [],
    skills: [],
    profile: WorkProfile::software(),
    questions: [],
    runs: [],
    progress,
    live: None,
    model_selection: None,
  }
}

///|
/// A model whose replica knows one ticket, plus the given progress list, so a
/// row can resolve the ticket title instead of falling back to its id.
fn progress_model(
  task_id : String,
  title : String,
  progress : Array[TicketProgress],
) -> Model {
  let task : Json = {
    "id": Json(task_id),
    "title": Json(title),
    "description": "",
    "stage": "running",
    "priority": "normal",
    "definition_of_done": [],
    "dependencies": [],
    "created_at_ms": 10,
    "updated_at_ms": 10,
    "ready_since_ms": null,
  }
  let frame = @protocol.encode_server_frame(
    Snapshot({
      protocol_version: 1,
      last_seq: 0L,
      board_revision: 1L,
      payload: {
        "board": { "revision": 1, "tasks": [task], "attempts": [] },
        "events": [],
      },
    }),
  )
  let replica = @client.BoardReplica::empty()
  guard replica.apply_text(frame) is Applied else {
    abort("Invalid progress test snapshot")
  }
  {
    ..apply_ticket_state(Model::empty(true), progress_state(progress)),
    replica,
    connection: Online,
  }
}

///|
test "worker progress decodes task, kind, message and time" {
  let text = "{\"type\":\"ticket_state\",\"state\":{\"questions\":[],\"runs\":[],\"progress\":[{\"task_id\":\"t1\",\"kind\":\"milestone\",\"message\":\"Halfway through the tests\",\"at_ms\":1700000000000},{\"task_id\":\"t1\",\"kind\":\"blocked\",\"message\":\"Waiting on a seam\",\"at_ms\":1700000060000}]}}"
  match ticket_frame(text) {
    Some(TicketSnapshot(state)) => {
      assert_eq(state.progress.length(), 2)
      assert_eq(state.progress[0].task_id, "t1")
      assert_eq(state.progress[0].kind, "milestone")
      assert_eq(state.progress[0].message, "Halfway through the tests")
      assert_eq(state.progress[0].at_ms, 1700000000000L)
      assert_eq(state.progress[1].kind, "blocked")
    }
    _ => fail("expected a ticket state frame")
  }
}

///|
test "absent worker progress decodes to an empty list" {
  let text = "{\"type\":\"ticket_state\",\"state\":{\"questions\":[],\"runs\":[]}}"
  match ticket_frame(text) {
    Some(TicketSnapshot(state)) => assert_eq(state.progress.length(), 0)
    _ => fail("expected a ticket state frame")
  }
}

///|
test "malformed progress entries are ignored one by one" {
  let text = "{\"type\":\"ticket_state\",\"state\":{\"questions\":[],\"runs\":[],\"progress\":[\"just a string\",{\"kind\":\"normal\",\"message\":\"no task\"},{\"task_id\":\"t1\",\"message\":\"   \"},{\"task_id\":\"\",\"message\":\"empty task\"},{\"task_id\":\"t2\",\"kind\":7,\"message\":\"numeric kind\",\"at_ms\":\"soon\"},{\"task_id\":\"t3\",\"kind\":\"attention\",\"message\":\"Needs a decision\",\"at_ms\":1700000000000}]}}"
  match ticket_frame(text) {
    Some(TicketSnapshot(state)) => {
      // Only the entry with a task and a real message survives; the numeric
      // kind reads as neutral and the unusable time reads as the epoch, so a
      // partially broken entry still shows what it can.
      assert_eq(state.progress.length(), 2)
      assert_eq(state.progress[0].task_id, "t2")
      assert_eq(state.progress[0].kind, "normal")
      assert_eq(state.progress[0].message, "numeric kind")
      assert_eq(state.progress[0].at_ms, 0L)
      assert_eq(state.progress[1].kind, "attention")
    }
    _ => fail("expected a ticket state frame")
  }
}

///|
test "unseen worker updates count until the inbox is opened" {
  let first = progress_update("t1", "normal", "Index built", 1700000000000L)
  let second = progress_update("t1", "milestone", "Tests green", 1700000060000L)
  let model = apply_ticket_state(
    Model::empty(true),
    progress_state([first, second]),
  )
  assert_eq(ticket_unseen_update_count(model), 2)
  assert_eq(ticket_inbox_count(model), 2)
  let (opened, _) = update(model, TicketDrawerOpened, test_emit, test_env())
  assert_true(opened.ticket_drawer)
  assert_eq(ticket_unseen_update_count(opened), 0)
  assert_eq(ticket_inbox_count(opened), 0)
  // A worker that speaks after the inbox was opened is unseen again.
  let third = progress_update(
    "t1", "attention", "Needs a decision", 1700000120000L,
  )
  let later = apply_ticket_state(opened, progress_state([first, second, third]))
  assert_eq(ticket_unseen_update_count(later), 1)
  assert_eq(ticket_inbox_count(later), 1)
  // Re-opening the inbox settles the badge again.
  let (reopened, _) = update(later, TicketDrawerOpened, test_emit, test_env())
  assert_eq(ticket_unseen_update_count(reopened), 0)
}

///|
test "the inbox badge still counts open questions" {
  let question : TicketQuestion = {
    id: "q1",
    task_id: "t1",
    question: "Ship it?",
    kind: "confirm",
    options: [],
    asked_at: 1L,
    asked_by: "worker",
    audience: "customer",
    status: "open",
  }
  let model = apply_ticket_state(Model::empty(true), {
    project: "",
    team: None,
    mcp_servers: [],
    skills: [],
    profile: WorkProfile::software(),
    questions: [question],
    runs: [],
    progress: [progress_update("t1", "normal", "Index built", 1700000000000L)],
    live: None,
    model_selection: None,
  })
  assert_eq(ticket_question_count(model), 1)
  assert_eq(ticket_unseen_update_count(model), 1)
  assert_eq(ticket_inbox_count(model), 2)
  // Opening the inbox clears only the updates; the question still waits.
  let (opened, _) = update(model, TicketDrawerOpened, test_emit, test_env())
  assert_eq(ticket_inbox_count(opened), 1)
}

///|
test "opening the inbox sends nothing and keeps the questions" {
  let model = apply_ticket_state(Model::empty(true), {
    project: "",
    team: None,
    mcp_servers: [],
    skills: [],
    profile: WorkProfile::software(),
    questions: [
      {
        id: "q1",
        task_id: "t1",
        question: "Ship it?",
        kind: "confirm",
        options: [],
        asked_at: 1L,
        asked_by: "worker",
        audience: "customer",
        status: "open",
      },
    ],
    runs: [],
    progress: [progress_update("t1", "normal", "Index built", 1700000000000L)],
    live: None,
    model_selection: None,
  })
  let (opened, command) = update(
    model,
    TicketDrawerOpened,
    test_emit,
    test_env(),
  )
  assert_eq(Repr(command).to_string(), Repr(@rabbita.none).to_string())
  assert_false(opened.ticket_sending)
  assert_eq(opened.ticket_drafts.length(), 0)
  assert_eq(opened.tickets.questions.length(), 1)
  // Marking updates seen never rewrites the authoritative list.
  assert_eq(opened.tickets.progress.length(), 1)
}

///|
test "inbox rows resolve title, tone and short time newest first" {
  let minute = 60000L
  let older = progress_update("t1", "normal", "Index built", 1700000000000L)
  let newer = progress_update(
    "t1",
    "attention",
    "Needs a decision",
    1700000000000L + 55L * minute,
  )
  let unknown = progress_update(
    "task-x", "blocked", "No worker", 1700000000000L,
  )
  let model = progress_model("t1", "Ship the board", [older, newer, unknown])
  let rows = inbox_updates(model, 1700000000000L + 60L * minute)
  assert_eq(rows.length(), 3)
  // Newest first, with the ticket title resolved from the replica.
  assert_eq(rows[0].task_id, "t1")
  assert_eq(rows[0].title, "Ship the board")
  assert_eq(rows[0].message, "Needs a decision")
  assert_eq(rows[0].kind_label, "Attention")
  assert_eq(rows[0].time_label, "5m ago")
  assert_true(rows[0].unseen)
  assert_eq(rows[1].time_label, "1h ago")
  assert_eq(rows[1].kind_label, "Update")
  // A ticket the replica cannot resolve falls back to its id, never a blank.
  assert_eq(rows[2].title, "task-x")
  assert_eq(rows[2].kind_label, "Blocked")
  // Opening the inbox flips the same rows to seen without changing them.
  let (opened, _) = update(model, TicketDrawerOpened, test_emit, test_env())
  let seen_rows = inbox_updates(opened, 1700000000000L + 60L * minute)
  assert_false(seen_rows[0].unseen)
  assert_eq(seen_rows[0].time_label, "5m ago")
  assert_eq(seen_rows[0].message, "Needs a decision")
}

///|
test "the activity dialog reads the newest update of its own ticket" {
  let first = progress_update("t1", "normal", "Index built", 1700000000000L)
  let second = progress_update("t1", "milestone", "Tests green", 1700000060000L)
  let other = progress_update("t2", "blocked", "Other worker", 1700000090000L)
  let model = apply_ticket_state(
    Model::empty(true),
    progress_state([first, second, other]),
  )
  match ticket_latest_update(model, "t1") {
    Some(update) => assert_eq(update.message, "Tests green")
    None => fail("expected the newest update of t1")
  }
  match ticket_latest_update(model, "t2") {
    Some(update) => assert_eq(update.message, "Other worker")
    None => fail("expected the newest update of t2")
  }
  assert_true(ticket_latest_update(model, "t3") is None)
}

///|
test "seen updates are pruned when their worker stops reporting them" {
  let kept = progress_update("t1", "normal", "Index built", 1700000000000L)
  let dropped = progress_update("t1", "normal", "Old build", 1699999000000L)
  let seen = ticket_progress_seen([kept, dropped])
  let surviving = ticket_progress_retain_seen(seen, [kept])
  assert_true(surviving.contains(ticket_progress_key(kept)))
  assert_false(surviving.contains(ticket_progress_key(dropped)))
  // After pruning, a re-delivery of the dropped update is unseen again.
  let model = apply_ticket_state(Model::empty(true), progress_state([dropped]))
  let pruned = { ..model, ticket_seen_updates: surviving, }
  assert_eq(ticket_unseen_update_count(pruned), 1)
}

///|
test "short time labels never invent a future age" {
  assert_eq(ticket_progress_age(1700000000000L, 1700000000000L), "just now")
  // A clock skew must not read as "in 3 minutes".
  assert_eq(ticket_progress_age(1700000180000L, 1700000000000L), "just now")
  assert_eq(
    ticket_progress_age(1700000000000L, 1700000000000L + 60000L),
    "1m ago",
  )
  assert_eq(
    ticket_progress_age(1700000000000L, 1700000000000L + 3600000L),
    "1h ago",
  )
  assert_eq(
    ticket_progress_age(1700000000000L, 1700000000000L + 172800000L),
    "2d ago",
  )
  // Older than a month falls back to absolute civil time.
  assert_eq(
    ticket_progress_age(1700000000000L, 1700000000000L + 3456000000L),
    "2023-11-14 22:13:20 UTC",
  )
}
