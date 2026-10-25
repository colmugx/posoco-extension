///|
/// Fixtures for the Retry-work action: runs are the only ticket journal state
/// these tests need, plus one replica task so the empty-state offer can read
/// the ticket's stage.
fn retry_run(task_id : String, status : String) -> TicketRun {
  {
    task_id,
    session_id: "s1",
    phase: "work",
    status,
    error: if status == "failed" {
      Some("provider timed out")
    } else {
      None
    },
    result: if status == "succeeded" {
      Some("Done")
    } else {
      None
    },
    steps: 3,
    current_tool: None,
    preview: "",
    reasoning: "",
    activities: [],
  }
}

///|
fn retry_ticket_model(runs : Array[TicketRun]) -> Model {
  apply_ticket_state(Model::empty(true), {
    questions: [],
    runs,
    progress: [],
    model_selection: None,
  })
}

///|
fn retry_task_json(id : String, title : String, stage : String) -> Json {
  {
    "id": Json(id),
    "title": Json(title),
    "description": "",
    "stage": Json(stage),
    "priority": "normal",
    "definition_of_done": [],
    "dependencies": [],
    "created_at_ms": 10,
    "updated_at_ms": 10,
    "ready_since_ms": null,
  }
}

///|
fn retry_task_model(id : String, stage : String) -> Model {
  let replica = @client.BoardReplica::empty()
  let applied = replica.apply_snapshot({
    protocol_version: 1,
    last_seq: 0L,
    board_revision: 1L,
    payload: {
      "board": {
        "revision": 1,
        "tasks": [retry_task_json(id, "Retryable ticket", stage)],
        "attempts": [],
      },
      "events": [],
    },
  })
  guard applied is @client.Applied else {
    abort("Invalid retry test snapshot")
  }
  {
    ..apply_ticket_state(Model::empty(true), TicketState::empty()),
    replica,
    connection: Online,
    ticket_activity_task: Some(id),
  }
}

///|
fn retry_json_field(value : Json, name : String) -> Json? {
  match value {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
test "retry work travels as a ticket command carrying only the task id" {
  let frame = @json.parse(
    ticket_command_frame("board.ticket.retry", ticket_retry_args("t1")),
  ) catch {
    _ => abort("the retry frame must encode as JSON")
  }
  assert_eq(retry_json_field(frame, "type"), Some(Json::string("ticket_command")))
  assert_eq(retry_json_field(frame, "name"), Some(Json::string("board.ticket.retry")))
  match retry_json_field(frame, "args") {
    Some(args) => {
      assert_eq(retry_json_field(args, "task_id"), Some(Json::string("t1")))
      // No session or run identity: the host starts a brand-new run.
      match args {
        Object(fields) => {
          assert_eq(fields.get("session_id"), None)
          assert_eq(fields.get("run_id"), None)
        }
        _ => fail("expected the retry args to be an object")
      }
    }
    None => fail("a retry command must carry its arguments")
  }
}

///|
test "retry work is gated by the in-flight command, the socket and the runtime" {
  let model = retry_ticket_model([retry_run("t1", "failed")])
  let (sent, _) = update(model, TicketRetry("t1"), test_emit, test_env())
  assert_true(sent.ticket_sending)
  assert_eq(sent.last_status, "Retrying ticket t1")
  assert_true(sent.tickets == model.tickets)
  let blocked = [
    { ..model, ticket_sending: true },
    { ..model, can_connect: false },
    { ..model, ticket_available: false },
    retry_ticket_model([retry_run("t1", "running")]),
  ]
  for candidate in blocked {
    let (next, _) = update(candidate, TicketRetry("t1"), test_emit, test_env())
    assert_true(next == candidate)
  }
  // A run on another ticket never blocks this ticket's retry.
  let other = retry_ticket_model([retry_run("t2", "running")])
  let (retried, _) = update(other, TicketRetry("t1"), test_emit, test_env())
  assert_true(retried.ticket_sending)
}

///|
test "only lost runs offer retry work" {
  let model = retry_ticket_model([])
  let emit : @rabbita.Emit[Msg] = _msg => @rabbita.none
  for status in ["failed", "interrupted", "sync_failed"] {
    assert_true(ticket_run_retryable(status))
    assert_true(
      ticket_run_action_block(model, retry_run("t1", status), emit) !=
      @html.nothing,
    )
  }
  // A successful run is a result to review, not a lost session.
  for status in ["succeeded", "shaped", "running", ""] {
    assert_false(ticket_run_retryable(status))
    assert_true(
      ticket_run_action_block(model, retry_run("t1", status), emit) ==
      @html.nothing,
    )
  }
  assert_true(ticket_retry_note().contains("new run"))
  assert_true(ticket_retry_note().contains("does not resume"))
}

///|
test "a live run keeps retry work disabled" {
  let running = retry_ticket_model([retry_run("t1", "running")])
  assert_true(ticket_retry_blocked(running, "t1"))
  assert_false(ticket_retry_blocked(running, "t2"))
  let finished = retry_ticket_model([retry_run("t1", "failed")])
  assert_false(ticket_retry_blocked(finished, "t1"))
  assert_true(ticket_retry_blocked({ ..finished, ticket_sending: true }, "t1"))
  assert_true(ticket_retry_blocked({ ..finished, can_connect: false }, "t1"))
  assert_true(ticket_retry_blocked({ ..finished, ticket_available: false }, "t1"))
  // The failed card still renders the offer; the gate only disables it.
  let emit : @rabbita.Emit[Msg] = _msg => @rabbita.none
  assert_true(
    ticket_run_action_block(
      running,
      retry_run("t1", "failed"),
      emit,
    ) != @html.nothing,
  )
}

///|
test "a suspended ticket without a run still offers retry work" {
  let emit : @rabbita.Emit[Msg] = _msg => @rabbita.none
  let suspended = retry_task_model("t1", "suspended")
  let task = task_by_id(suspended.replica, "t1")
  assert_true(task is Some(_))
  assert_true(
    ticket_stage_retry_action(suspended, task, "t1", emit) != @html.nothing,
  )
  // Ready keeps its own Run action and Done is terminal: no retry there.
  for stage in ["ready", "review", "running", "done", "cancelled", "created"] {
    let model = retry_task_model("t1", stage)
    assert_true(
      ticket_stage_retry_action(
        model,
        task_by_id(model.replica, "t1"),
        "t1",
        emit,
      ) ==
      @html.nothing,
    )
  }
  // A run already on the ticket is offered by its run card, not by stage.
  let with_run = {
    ..suspended,
    tickets: {
      questions: [],
      runs: [retry_run("t1", "failed")],
      progress: [],
      model_selection: None,
    },
  }
  assert_true(
    ticket_stage_retry_action(
      with_run,
      task_by_id(with_run.replica, "t1"),
      "t1",
      emit,
    ) ==
    @html.nothing,
  )
}
