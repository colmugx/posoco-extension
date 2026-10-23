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
    questions: [
      {
        id: "q1",
        task_id: "t1",
        question: "Ship it?",
        kind: "confirm",
        options: [],
        asked_at: 1L,
      },
    ],
    runs: [],
  }
  let model = apply_ticket_state(Model::empty(true), state)
  assert_true(model.ticket_available)
  assert_false(model.ticket_drawer)
  assert_eq(ticket_question_count(model), 1)
  assert_eq(ready_ticket_count(model), 0)
}

///|
test "running ticket activity stays in the inbox" {
  let text = "{\"type\":\"ticket_state\",\"state\":{\"questions\":[],\"runs\":[{\"task_id\":\"t1\",\"session_id\":\"s1\",\"phase\":\"shape\",\"status\":\"running\",\"error\":null,\"result\":null,\"steps\":1,\"current_tool\":\"read\",\"preview\":\"Looking at the files\",\"reasoning\":\"Need context\",\"activities\":[{\"at_ms\":1,\"kind\":\"tool\",\"text\":\"Tool · read · src/main.mbt\"}]}]}}"
  match ticket_frame(text) {
    Some(TicketSnapshot(state)) => {
      let model = apply_ticket_state(Model::empty(true), state)
      assert_eq(ticket_inbox_count(model), 1)
      assert_eq(state.runs[0].steps, 1)
      assert_eq(state.runs[0].activities.length(), 1)
      assert_eq(state.runs[0].activities[0].kind, "tool")
    }
    _ => fail("expected a ticket state frame")
  }
}

///|
test "failed runs stay in the inbox with their error" {
  let state : TicketState = {
    questions: [],
    runs: [
      {
        task_id: "t1",
        session_id: "s1",
        phase: "work",
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
  }
  let model = apply_ticket_state(Model::empty(true), state)
  assert_eq(ticket_inbox_count(model), 1)
  assert_true(model.tickets.runs[0].error is Some(_))
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
test "already-running rejection opens the inbox with a readable reason" {
  let model = apply_ticket_outcome(
    Model::empty(true),
    false,
    Some("ticket is already running"),
    None,
  )
  assert_true(model.ticket_drawer)
  match model.notice {
    Some(notice) => assert_true(notice.text.contains("already running"))
    None => fail("expected a rejection notice")
  }
}
