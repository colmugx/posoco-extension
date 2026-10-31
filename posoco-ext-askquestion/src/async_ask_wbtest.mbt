///|
/// Non-blocking ask: submit returns immediately, answers are delivered to the
/// next model call exactly once, and expiry is a delivery-time fact.

///|
fn notify_call(id : String, arguments : Json) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked(id),
    name: @posoco.ToolName::unchecked("notify_user"),
    arguments,
  }
}

///|
fn recorded_ctx(call : @posoco.ToolCall) -> @posoco.ToolCallContext {
  @posoco.ToolCallContext(
    effect_id=@kernel.EffectId::{ value: 0, },
    call_id=call.call_id,
    name=call.name,
    arguments=call.arguments,
    register_cancel=fn(_ : &@posoco.ToolCancellable) { () },
  )
}

///|
fn select_call(id : String, options : Array[String]) -> @posoco.ToolCall {
  let opts : Array[Json] = []
  for option in options {
    opts.push(Json::string(option))
  }
  notify_call(
    id,
    Json::object({
      "question": Json::string("Pick one"),
      "type": Json::string("select"),
      "options": Json::array(opts),
    }),
  )
}

///|
fn user_messages(messages : Array[@posoco.Message]) -> Array[String] {
  let out : Array[String] = []
  for message in messages {
    match message {
      @posoco.Message::UserMessage(content~) => {
        let text = StringBuilder()
        for block in content {
          match block {
            @posoco.Content::Text(value) => text.write_string(value)
            _ => ()
          }
        }
        out.push(text.to_string())
      }
      _ => ()
    }
  }
  out
}

///|
/// The notify_user submit path succeeds without waiting and never touches
/// the UI port.
async test "notify_user_submits_without_blocking" {
  let ui = ScriptedUi(@posoco.UiResponse::Text("unused"))
  let tools = AskQuestionTools()
  tools.ui = Some(ui as &@posoco.UiPort)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    recorded_ctx(
      notify_call(
        "call-1",
        Json::object({ "question": Json::string("Which env?") }),
      ),
    ),
  )
  let structured = match outcome {
    @posoco.ToolOutcome::Success(structured~, ..) =>
      match structured {
        Some(value) => value
        None => fail("expected structured receipt")
      }
    _ => fail("expected submit success")
  }
  assert_true(structured.stringify().contains("\"status\":\"submitted\""))
  assert_true(structured.stringify().contains("\"short_id\":\"@q1\""))
  // A blocking ask would have called the UI port.
  assert_eq(ui.request_count, 0)
  assert_eq(tools.open_questions().length(), 1)
}

///|
/// An answer is carried into the next model call and only once.
async test "notify_user_answer_is_injected_once" {
  let tools = AskQuestionTools()
  ignore(
    @posoco.ToolProvider::execute(
      tools,
      recorded_ctx(
        notify_call(
          "call-1",
          Json::object({ "question": Json::string("Which env?") }),
        ),
      ),
    ),
  )
  let answered = tools.answer_async(
    question_id="question-1",
    response=@posoco.UiResponse::Text("  staging   please "),
  )
  match answered {
    Ok(_) => ()
    Err(error) =>
      fail("expected the answer to be accepted: \{error.to_string()}")
  }
  let first = @posoco.PipelineHook::before_model(tools, [])
  let texts = user_messages(first)
  assert_eq(texts.length(), 1)
  assert_eq(texts[0], "[question-reply id=question-1] answer: staging please")
  // Delivery is the drain: the same answer never arrives twice.
  let second = @posoco.PipelineHook::before_model(tools, [])
  assert_eq(second.length(), 0)
  assert_eq(tools.open_questions().length(), 0)
}

///|
/// Answers can resolve the short UI form and still land on the full id.
async test "notify_user_answer_accepts_short_and_at_ids" {
  let tools = AskQuestionTools()
  ignore(
    @posoco.ToolProvider::execute(
      tools,
      recorded_ctx(
        notify_call(
          "call-1",
          Json::object({
            "question": Json::string("Ok?"),
            "type": Json::string("confirm"),
          }),
        ),
      ),
    ),
  )
  match
    tools.answer_async(question_id="@q1", response=@posoco.UiResponse::Yes) {
    Ok(_) => ()
    Err(error) => fail("expected @q1 to resolve: \{error.to_string()}")
  }
  let texts = user_messages(@posoco.PipelineHook::before_model(tools, []))
  assert_eq(texts[0], "[question-reply id=question-1] answer: yes")
}

///|
/// Select answers project the chosen option; out-of-range and wrong-kind
/// answers are refused without touching the first accepted answer.
async test "notify_user_rejects_wrong_kind_and_duplicates" {
  let tools = AskQuestionTools()
  ignore(
    @posoco.ToolProvider::execute(
      tools,
      recorded_ctx(select_call("call-1", ["A", "B"])),
    ),
  )
  match
    tools.answer_async(
      question_id="question-1",
      response=@posoco.UiResponse::Selected(2),
    ) {
    Err(AsyncAskError::IndexOutOfRange(index~, ..)) => assert_eq(index, 2)
    _ => fail("expected index refusal")
  }
  match
    tools.answer_async(
      question_id="question-1",
      response=@posoco.UiResponse::Text("A"),
    ) {
    Err(AsyncAskError::WrongAnswerKind(expected~, ..)) =>
      assert_eq(expected, "select")
    _ => fail("expected kind refusal")
  }
  match
    tools.answer_async(
      question_id="question-1",
      response=@posoco.UiResponse::Selected(1),
    ) {
    Ok(_) => ()
    Err(error) => fail("expected select answer: \{error.to_string()}")
  }
  match
    tools.answer_async(
      question_id="question-1",
      response=@posoco.UiResponse::Selected(0),
    ) {
    Err(AsyncAskError::AlreadyAnswered(..)) => ()
    _ => fail("expected duplicate refusal")
  }
  let texts = user_messages(@posoco.PipelineHook::before_model(tools, []))
  assert_eq(texts[0], "[question-reply id=question-1] answer: B (index 1)")
}

///|
/// A question past its deadline is reported as expired, and an answer that
/// arrives afterwards cannot revive it.
async test "notify_user_expired_question_delivers_expiry" {
  let tools = AskQuestionTools::with_async_timeout(async_timeout_ms=60_000L)
  ignore(
    @posoco.ToolProvider::execute(
      tools,
      recorded_ctx(
        notify_call(
          "call-1",
          Json::object({ "question": Json::string("Still there?") }),
        ),
      ),
    ),
  )
  // The deadline is absolute, so drive the drain past it explicitly instead
  // of sleeping in a test.
  let open = tools.open_questions()
  assert_eq(open.length(), 1)
  let far_future = open[0].deadline_at + 1L
  let drained = tools.drain_answers_for_test(now=far_future)
  assert_eq(drained.length(), 1)
  match drained[0] {
    Expired(question~) => assert_eq(question.id, "question-1")
    Answered(..) => fail("expected expiry")
  }
  // The envelope the model would have seen on that model call.
  let envelope = match async_env_lines(drained) {
    Some(text) => text
    None => fail("expected an envelope")
  }
  assert_true(envelope.contains("[question-expired id=question-1]"))
  // Expiry was delivered: nothing is pending for the next model call.
  assert_eq(@posoco.PipelineHook::before_model(tools, []).length(), 0)
  // A late answer is refused with its real reason, not "unknown".
  match
    tools.answer_async(
      question_id="question-1",
      response=@posoco.UiResponse::Text("too late"),
    ) {
    Err(AsyncAskError::Expired(..)) => ()
    _ => fail("expected late answer to be refused")
  }
  assert_eq(@posoco.PipelineHook::before_model(tools, []).length(), 0)
}

///|
/// Captures wakeup requests so the turn-end policy is observable without a
/// composed Agent.
priv struct RecordingWakeup {
  requests : Array[(String, String)]
}

///|
fn RecordingWakeup::RecordingWakeup() -> RecordingWakeup {
  { requests: [], }
}

///|
fn RecordingWakeup::port(self : RecordingWakeup) -> @posoco.WakeupPort {
  let request : (String, String, String) -> Result[
    @posoco.WakeupTicket,
    @posoco.WakeupError,
  ] = fn(session, tag, _note) {
    self.requests.push((session, tag))
    let ticket : @posoco.WakeupTicket = {
      id: "ticket-1",
      session,
      tag,
      enqueued_at: 0L,
    }
    Ok(ticket)
  }
  @posoco.WakeupPort::from_request(request~)
}

///|
/// An undelivered answer at turn end asks for one ordinary turn; a turn with
/// nothing to deliver asks for none.
async test "notify_user_requests_one_wakeup_at_turn_end" {
  let tools = AskQuestionTools()
  let recorder = RecordingWakeup::RecordingWakeup()
  tools.wakeup = Some(recorder.port())
  tools.set_session(session="session-1")
  // Nothing pending yet: no wakeup.
  @posoco.PipelineHook::on_turn_end(tools)
  assert_eq(recorder.requests.length(), 0)
  ignore(
    @posoco.ToolProvider::execute(
      tools,
      recorded_ctx(
        notify_call(
          "call-1",
          Json::object({ "question": Json::string("Which env?") }),
        ),
      ),
    ),
  )
  // A question awaiting an answer is not an undelivered answer: the answer
  // itself is what needs a turn. Still no wakeup.
  @posoco.PipelineHook::on_turn_end(tools)
  assert_eq(recorder.requests.length(), 0)
  match
    tools.answer_async(
      question_id="question-1",
      response=@posoco.UiResponse::Text("staging"),
    ) {
    Ok(_) => ()
    Err(error) =>
      fail("expected the answer to be accepted: \{error.to_string()}")
  }
  @posoco.PipelineHook::on_turn_end(tools)
  assert_eq(recorder.requests.length(), 1)
  assert_eq(recorder.requests[0].0, "session-1")
  assert_eq(recorder.requests[0].1, "askquestion-answer")
  // The next model call delivers it and the turn-end policy goes quiet.
  assert_eq(@posoco.PipelineHook::before_model(tools, []).length(), 1)
  @posoco.PipelineHook::on_turn_end(tools)
  assert_eq(recorder.requests.length(), 1)
}

///|
/// A host without the wakeup capability degrades to lazy delivery instead of
/// crashing, and shutdown drops every parked answer.
async test "notify_user_degrades_without_wakeup_and_clears_on_shutdown" {
  let tools = AskQuestionTools()
  ignore(
    @posoco.ToolProvider::execute(
      tools,
      recorded_ctx(
        notify_call(
          "call-1",
          Json::object({ "question": Json::string("Which env?") }),
        ),
      ),
    ),
  )
  match
    tools.answer_async(
      question_id="question-1",
      response=@posoco.UiResponse::Text("staging"),
    ) {
    Ok(_) => ()
    Err(error) =>
      fail("expected the answer to be accepted: \{error.to_string()}")
  }
  // No wakeup port and no session: the policy must be a silent no-op.
  @posoco.PipelineHook::on_turn_end(tools)
  assert_true(tools.has_undelivered())
  tools.shutdown_answers()
  assert_true(!tools.has_undelivered())
  assert_eq(@posoco.PipelineHook::before_model(tools, []).length(), 0)
}

///|
/// Answering one question settles exactly that question. There is no
/// "plain input" hook that could withdraw the rest, so a host that submits
/// ordinary text merely to carry an id-bound reply cannot lose the other
/// questions the user still owes.
async test "notify_user_answer_leaves_other_questions_open" {
  let tools = AskQuestionTools()
  let answered : Array[String] = []
  tools.subscribe(fn(event) {
    match event {
      Answered(question_id~) => answered.push(question_id)
      _ => ()
    }
  })
  ignore(
    @posoco.ToolProvider::execute(
      tools,
      recorded_ctx(select_call("call-1", ["staging", "production"])),
    ),
  )
  ignore(
    @posoco.ToolProvider::execute(
      tools,
      recorded_ctx(
        notify_call(
          "call-2",
          Json::object({ "question": Json::string("Node 22?") }),
        ),
      ),
    ),
  )
  assert_eq(tools.open_questions().length(), 2)
  match
    tools.answer_async(
      question_id="question-1",
      response=@posoco.UiResponse::Selected(0),
    ) {
    Ok(_) => ()
    Err(error) =>
      fail("expected the first answer to be accepted: \{error.to_string()}")
  }
  // Only the answered id leaves the open set.
  assert_eq(answered, ["question-1"])
  let open = tools.open_questions()
  assert_eq(open.length(), 1)
  assert_eq(open[0].id, "question-2")
  // The pending answer envelope names q1 only.
  let outcomes = tools.drain_answers_for_test(now=2L)
  assert_eq(outcomes.length(), 1)
  match outcomes[0] {
    Answered(question~, ..) => assert_eq(question.id, "question-1")
    _ => fail("expected one answered outcome")
  }
  // The second question is still answerable, and that answer is its own.
  match
    tools.answer_async(
      question_id="question-2",
      response=@posoco.UiResponse::Text("22"),
    ) {
    Ok(_) => ()
    Err(error) =>
      fail("expected the second answer to be accepted: \{error.to_string()}")
  }
  assert_eq(tools.open_questions().length(), 0)
  assert_eq(answered, ["question-1", "question-2"])
}
