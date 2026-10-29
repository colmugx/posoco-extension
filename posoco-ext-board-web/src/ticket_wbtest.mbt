///|
test "ticket state decodes the question drawer payload" {
  let text = "{\"type\":\"ticket_state\",\"state\":{\"questions\":[{\"id\":\"q1\",\"task_id\":\"t1\",\"question\":\"Ship it?\",\"kind\":\"select\",\"options\":[\"A\",\"B\"],\"asked_at\":12}],\"runs\":[{\"task_id\":\"t1\",\"session_id\":\"s1\",\"status\":\"running\",\"error\":null}]}}"
  match ticket_frame(text) {
    Some(TicketSnapshot(state)) => {
      assert_eq(state.questions.length(), 1)
      assert_eq(state.questions[0].id, "q1")
      assert_eq(state.questions[0].question, "Ship it?")
      assert_eq(state.questions[0].options, ["A", "B"])
      assert_eq(state.runs.length(), 1)
      assert_eq(state.runs[0].status, "running")
    }
    _ => fail("expected a ticket state frame")
  }
}

///|
test "ticket state records questions without forcing the drawer" {
  let state : TicketState = {
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
        audience: "product_owner",
        status: "open",
      },
    ],
    runs: [],
    progress: [],
    live: None,
    model_selection: None,
  }
  let model = apply_ticket_state(Model::empty(true), state)
  assert_true(model.ticket_available)
  assert_false(model.ticket_drawer)
  assert_eq(ticket_question_count(model), 1)
  assert_eq(ready_ticket_count(model), 0)
}

///|
test "running ticket activity belongs to the ticket, not the question inbox" {
  let text = "{\"type\":\"ticket_state\",\"state\":{\"questions\":[],\"runs\":[{\"task_id\":\"t1\",\"session_id\":\"s1\",\"phase\":\"shape\",\"status\":\"running\",\"error\":null,\"result\":null,\"steps\":1,\"current_tool\":\"read\",\"preview\":\"Looking at the files\",\"reasoning\":\"Need context\",\"activities\":[{\"at_ms\":1,\"kind\":\"tool\",\"text\":\"Tool · read · src/main.mbt\"}]}]}}"
  match ticket_frame(text) {
    Some(TicketSnapshot(state)) => {
      let model = apply_ticket_state(Model::empty(true), state)
      assert_eq(ticket_inbox_count(model), 0)
      assert_eq(state.runs[0].steps, 1)
      assert_eq(state.runs[0].activities.length(), 1)
      assert_eq(state.runs[0].activities[0].kind, "tool")
    }
    _ => fail("expected a ticket state frame")
  }
}

///|
test "failed runs belong to the ticket, not the question inbox" {
  let state : TicketState = {
    project: "",
    team: None,
    mcp_servers: [],
    skills: [],
    profile: WorkProfile::software(),
    questions: [],
    runs: [
      {
        task_id: "t1",
        session_id: "s1",
        phase: "work",
        role: "rd",
        status: "failed",
        error: Some("provider timed out"),
        result: None,
        steps: 2,
        current_tool: None,
        preview: "",
        reasoning: "",
        activities: [],
      },
    ],
    progress: [],
    live: None,
    model_selection: None,
  }
  let model = apply_ticket_state(Model::empty(true), state)
  assert_eq(ticket_inbox_count(model), 0)
  assert_true(model.tickets.runs[0].error is Some(_))
}

///|
test "opening ticket activity tracks the selected ticket" {
  let (opened, _) = update(
    Model::empty(true),
    TicketActivityOpened("t1"),
    test_emit,
    test_env(),
  )
  assert_eq(opened.ticket_activity_task, Some("t1"))
  let (closed, _) = update(opened, TicketActivityClosed, test_emit, test_env())
  assert_eq(closed.ticket_activity_task, None)
}

///|
test "ticket commands stay inert until the host advertises the inbox" {
  let model = Model::empty(true)
  let (inert, _) = update(model, TicketRun("t"), test_emit, test_env())
  assert_false(inert.ticket_sending)
  let available = { ..model, ticket_available: true, }
  let (started, _) = update(available, TicketRun("t"), test_emit, test_env())
  assert_true(started.ticket_sending)
}

///|
test "already-running rejection points at the ticket activity dialog" {
  let model = apply_ticket_outcome(
    Model::empty(true),
    false,
    Some("ticket is already running"),
    None,
  )
  assert_false(model.ticket_drawer)
  match model.notice {
    Some(notice) => assert_true(notice.text.contains("Activity"))
    None => fail("expected a rejection notice")
  }
}

///|
test "three-line user stories render as three rows" {
  let lines = user_story_lines(
    "作为团队\n我希望看到活动\n以便确认工作在进行",
  )
  assert_eq(lines.length(), 3)
  assert_eq(lines[0], "作为团队")
  assert_eq(lines[1], "我希望看到活动")
  assert_eq(lines[2], "以便确认工作在进行")
}

///|
test "empty legacy story labels do not become a fake story" {
  assert_eq(user_story_lines("As a , I want , so that "), [
    "As a , I want , so that ",
  ])
  assert_eq(user_story_lines("As a user, I want , so that value"), [
    "As a user, I want , so that value",
  ])
}

///|
test "legacy comma story keeps all three parts" {
  assert_eq(user_story_lines("As a user, I want export, so that I can share"), [
    "As a user",
    "I want export",
    "So that I can share",
  ])
}
