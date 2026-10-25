///|
/// Fixture for one finished run with an explicit durable-session handle: the
/// host only keeps `session_id` for a run that survived an interruption.
fn resume_run(
  task_id : String,
  status : String,
  session_id : String,
) -> TicketRun {
  { ..retry_run(task_id, status), session_id, }
}

///|
fn resume_json_field(value : Json, name : String) -> Json? {
  match value {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
test "resume travels as a ticket command carrying only the task id" {
  let frame = @json.parse(
    ticket_command_frame("board.ticket.resume", ticket_resume_args("t1")),
  ) catch {
    _ => abort("the resume frame must encode as JSON")
  }
  assert_eq(
    resume_json_field(frame, "type"),
    Some(Json::string("ticket_command")),
  )
  assert_eq(
    resume_json_field(frame, "name"),
    Some(Json::string("board.ticket.resume")),
  )
  match resume_json_field(frame, "args") {
    Some(args) => {
      assert_eq(resume_json_field(args, "task_id"), Some(Json::string("t1")))
      // The durable session is host state: only the ticket identity travels.
      match args {
        Object(fields) => {
          assert_eq(fields.get("session_id"), None)
          assert_eq(fields.get("run_id"), None)
        }
        _ => fail("expected the resume args to be an object")
      }
    }
    None => fail("a resume command must carry its arguments")
  }
  // Resume sends through the same socket path every ticket command uses.
  assert_true(
    Repr(ticket_resume("t1", test_emit)).to_string().contains("WebSocketSend"),
  )
}

///|
test "resume is gated by the command, the socket, the runtime and a live run" {
  let model = retry_ticket_model([resume_run("t1", "interrupted", "s1")])
  let (sent, _) = update(model, TicketResume("t1"), test_emit, test_env())
  assert_true(sent.ticket_sending)
  assert_eq(sent.last_status, "Resuming ticket t1")
  // No optimistic run: the host owns what the resumed session does next.
  assert_true(sent.tickets == model.tickets)
  let blocked = [
    { ..model, ticket_sending: true, },
    { ..model, can_connect: false, },
    { ..model, ticket_available: false, },
    retry_ticket_model([
      resume_run("t1", "interrupted", "s1"),
      resume_run("t1", "running", ""),
    ]),
  ]
  for candidate in blocked {
    let (next, _) = update(candidate, TicketResume("t1"), test_emit, test_env())
    assert_true(next == candidate)
  }
  // A live run on another ticket never blocks this ticket's resume.
  let other = retry_ticket_model([resume_run("t2", "running", "")])
  let (resumed, _) = update(other, TicketResume("t1"), test_emit, test_env())
  assert_true(resumed.ticket_sending)
}

///|
test "a durable session makes failed and interrupted runs resumable" {
  let interrupted = resume_run("t1", "interrupted", "s1")
  assert_true(ticket_run_resumable(interrupted))
  // Resume run is primary and Retry follows as the way to start over.
  let actions = ticket_run_actions(interrupted)
  assert_eq(actions.length(), 2)
  assert_true(actions[0] is ResumeRun)
  assert_true(actions[1] is RetryRun)
  // An interruption whose session did not survive can only be retried.
  let lost = resume_run("t1", "interrupted", "")
  assert_false(ticket_run_resumable(lost))
  let retry_only = ticket_run_actions(lost)
  assert_eq(retry_only.length(), 1)
  assert_true(retry_only[0] is RetryRun)
  for status in ["failed", "sync_failed"] {
    let run = resume_run("t1", status, "s1")
    assert_true(ticket_run_resumable(run))
    let actions = ticket_run_actions(run)
    assert_eq(actions.length(), 2)
    assert_true(actions[0] is ResumeRun)
    assert_true(actions[1] is RetryRun)
  }
  // A running run is owned by its worker; a succeeded one is a result.
  for status in ["running", "succeeded", "shaped", ""] {
    let run = resume_run("t1", status, "s1")
    assert_false(ticket_run_resumable(run))
    assert_eq(ticket_run_actions(run).length(), 0)
  }
}

///|
test "the durable-run action is not the stage-move Resume" {
  assert_eq(ticket_run_action_label(ResumeRun), "Resume run")
  assert_eq(ticket_run_action_label(RetryRun), "Retry work")
  // The card's Suspended → Ready move keeps the bare label.
  assert_true(
    ticket_run_action_label(ResumeRun) != primary_action_label(Suspended),
  )
}

///|
test "an interrupted run renders both actions while a failed run keeps retry" {
  let model = retry_ticket_model([])
  let emit : @rabbita.Emit[Msg] = _msg => @rabbita.none
  let interrupted = resume_run("t1", "interrupted", "s1")
  assert_true(
    ticket_run_action_block(model, interrupted, emit) != @html.nothing,
  )
  let failed = resume_run("t1", "failed", "s1")
  assert_true(ticket_run_action_block(model, failed, emit) != @html.nothing)
  // Neither the live run nor the finished result carries an action block.
  for status in ["running", "succeeded"] {
    let run = resume_run("t1", status, "s1")
    assert_true(ticket_run_action_block(model, run, emit) == @html.nothing)
  }
}

///|
test "resume stays enabled until a run is live again" {
  let finished = retry_ticket_model([resume_run("t1", "interrupted", "s1")])
  assert_false(ticket_resume_blocked(finished, "t1"))
  assert_false(ticket_resume_blocked(finished, "t2"))
  let live = retry_ticket_model([
    resume_run("t1", "interrupted", "s1"),
    resume_run("t1", "running", ""),
  ])
  assert_true(ticket_resume_blocked(live, "t1"))
  assert_true(
    ticket_resume_blocked({ ..finished, ticket_sending: true, }, "t1"),
  )
  assert_true(ticket_resume_blocked({ ..finished, can_connect: false, }, "t1"))
  assert_true(
    ticket_resume_blocked({ ..finished, ticket_available: false, }, "t1"),
  )
  // The gate only disables the buttons: the offer still renders.
  let emit : @rabbita.Emit[Msg] = _msg => @rabbita.none
  assert_true(
    ticket_run_action_block(live, resume_run("t1", "interrupted", "s1"), emit) !=
    @html.nothing,
  )
}

///|
test "the interrupted note separates continuing from starting over" {
  let note = ticket_resume_note()
  assert_true(note.contains("Resume run"))
  assert_true(note.contains("durable session"))
  assert_true(note.contains("Retry starts a new run"))
  assert_true(note.contains("clears"))
  // Retry keeps its own note: it never claims to resume anything.
  assert_true(ticket_retry_note().contains("does not resume"))
}

///|
test "a suspended ticket with no run offers retry and never resume" {
  let emit : @rabbita.Emit[Msg] = _msg => @rabbita.none
  let suspended = retry_task_model("t1", "suspended")
  assert_true(suspended.tickets.runs.is_empty())
  assert_true(
    ticket_stage_retry_action(
      suspended,
      task_by_id(suspended.replica, "t1"),
      "t1",
      emit,
    ) !=
    @html.nothing,
  )
  // No run card exists, so there is no durable session to offer Resume run for.
  assert_false(suspended.tickets.runs.any(run => ticket_run_resumable(run)))
}
