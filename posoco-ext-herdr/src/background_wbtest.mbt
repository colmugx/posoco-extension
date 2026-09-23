///|
/// Background wiring tests: the delegation runs through the shared channel
/// flow scripted on FakeHerdrCli (see herdr_delegate_wbtest.mbt) — no real
/// herdr CLI, no cetas-headless process.

///|
/// Content of the first Success tool result in a transcript, if any.
fn bg_success_tool_text(messages : Array[@posoco.Message]) -> String? {
  for message in messages {
    match message {
      @posoco.Message::ToolMessage(outcome~, ..) =>
        match outcome {
          @posoco.ToolOutcome::Success(content~, ..) => return Some(content)
          _ => ()
        }
      _ => ()
    }
  }
  None
}

///|
/// Concatenated Text parts of one message content array.
fn bg_content_text(content : Array[@posoco.Content]) -> String {
  let parts : Array[String] = []
  for item in content {
    match item {
      @posoco.Content::Text(text) => parts.push(text)
      _ => ()
    }
  }
  parts.join("")
}

///|
/// Text of the first user message carrying core's task-outcome envelope.
fn bg_user_envelope(messages : Array[@posoco.Message]) -> String? {
  for message in messages {
    match message {
      @posoco.Message::UserMessage(content~) => {
        let text = bg_content_text(content)
        if text.contains("[posoco-task-outcome id=") {
          return Some(text)
        }
      }
      _ => ()
    }
  }
  None
}

///|
/// Concatenated text of one recorded model-call input.
fn bg_input_text(messages : Array[@posoco.Message]) -> String {
  let parts : Array[String] = []
  for message in messages {
    let text = match message {
      @posoco.Message::SystemMessage(content~) => bg_content_text(content)
      @posoco.Message::UserMessage(content~) => bg_content_text(content)
      @posoco.Message::AssistantMessage(content~, ..) =>
        bg_content_text(content)
      @posoco.Message::ToolMessage(outcome~, ..) => outcome.summary()
    }
    parts.push(text)
  }
  parts.join("\n")
}

///|
test "background alone parses; background with session is refused at parse" {
  match
    extract_delegate_args(
      Json::object(
        Map::from_array([
          ("task", Json::string("t")),
          ("background", Json::boolean(true)),
        ]),
      ),
    ) {
    Ok(args) => assert_true(args.background)
    Err(message) => fail("background alone must parse, got: " + message)
  }
  match
    extract_delegate_args(
      Json::object(
        Map::from_array([
          ("task", Json::string("t")),
          ("background", Json::boolean(true)),
          ("session", Json::string("sess-1")),
        ]),
      ),
    ) {
    Err(message) => {
      assert_true(message.contains("fresh child"))
      assert_true(message.contains("foreground"))
    }
    Ok(_) => fail("expected background+session refusal")
  }
  match
    extract_delegate_args(
      Json::object(
        Map::from_array([
          ("task", Json::string("t")),
          ("background", Json::string("yes")),
        ]),
      ),
    ) {
    Err(message) =>
      assert_true(message.contains("'background' must be a boolean"))
    Ok(_) => fail("expected background type refusal")
  }
}

///|
async test "background without composition is an explicit tool error" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = { results: [], index: 0, received: [], }
  let outcome = delegate.execute_delegate_impl(
    fake,
    delegate_call([
      ("task", Json::string("x")),
      ("background", Json::boolean(true)),
    ]),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("composed task capability"))
    other =>
      fail(
        "expected explicit refusal without composition, got " +
        other.to_string(),
      )
  }
  assert_eq(fake.received.length(), 0)
  assert_eq(delegate.active, 0)
}

///|
async test "background receipt accepted and channel outcome delivered next turn" {
  let fake : FakeHerdrCli = {
    results: happy_script("sess-child"),
    index: 0,
    received: [],
  }
  let bg_args : HerdrDelegateArgs = {
    task: "delegate me",
    permission: "readonly",
    model: None,
    effort: None,
    session: None,
    timeout_ms: 1800000,
    direction: "right",
    close_pane: true,
    background: true,
  }
  let delegate = test_delegate(
    background_run=Some(async fn(d : HerdrDelegate) {
      d.run_channel(fake, bg_args)
    }),
  )
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response(
        "herdr_delegate",
        "call-1",
        Json::object(
          Map::from_array([
            ("task", Json::string("delegate me")),
            ("background", Json::boolean(true)),
          ]),
        ),
      ),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("receipt ok")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("outcome seen")),
  ])
  let store = @posoco.RecordingSessionStore()
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store]),
      delegate as &@posoco.Extension,
    ],
    config=@posoco.tk_config(),
  )
  ignore(
    agent.run_scoped(async fn(agent) {
      ignore(agent.run_turn(@posoco.tk_user_msg("go"), "sess_1"))
      @async.sleep(300)
      ignore(agent.run_turn(@posoco.tk_user_msg("again"), "sess_1"))
    }),
  )
  // The runner executed the full channel flow through the fake CLI.
  assert_eq(fake.received.length(), 5)
  assert_eq(model.call_count(), 3)
  let persisted = (store as &@posoco.SessionStore).load("sess_1")
  guard bg_success_tool_text(persisted.messages) is Some(receipt) else {
    fail("expected the receipt as a Success tool result in the transcript")
  }
  assert_true(receipt.contains("background herdr_delegate accepted"))
  assert_true(receipt.contains("delegation_id: "))
  // The next same-session turn carried core's delivery envelope with the
  // pane answer and the child_session footer.
  guard bg_user_envelope(persisted.messages) is Some(envelope) else {
    fail("expected a [posoco-task-outcome] user envelope in the transcript")
  }
  assert_true(envelope.contains("headless answer body"))
  assert_true(envelope.contains("child_session: sess-child"))
  // The outcome reached the model input of the follow-up turn.
  let prompt = bg_input_text(model.received_messages[2])
  assert_true(prompt.contains("[posoco-task-outcome id="))
  assert_true(prompt.contains("headless answer body"))
}

///|
/// Fake channel that masks cancellation: every call sleeps until the timeout
/// cancels it, swallows the cancellation, and returns a canned result —
/// masking shape (b) (catch-and-return), the worst shape for core's timeout
/// classification.
priv struct MaskingHerdrCli {
  received : Array[Array[String]]
}

///|
impl HerdrCli for MaskingHerdrCli with fn run(
  self : MaskingHerdrCli,
  argv : Array[String],
) -> (Int, String, String) raise @posoco.RuntimeError {
  self.received.push(argv)
  let swallowed : Result[Unit, Error] = Ok(@async.sleep(10000))
  ignore(swallowed)
  (0, "masked", "")
}

///|
async test "background runner guard: masked cancellation still surfaces as TimeoutError" {
  let masking : MaskingHerdrCli = { received: [], }
  let delegate = test_delegate()
  let args : HerdrDelegateArgs = {
    task: "hang",
    permission: "readonly",
    model: None,
    effort: None,
    session: None,
    timeout_ms: 100,
    direction: "right",
    close_pane: true,
    background: true,
  }
  let runner = delegate.background_task_run(async fn(d : HerdrDelegate) {
    d.run_channel(masking, args)
  })
  // Mirror background_execute's accept-time reservation: the runner owns the
  // release side of one in-flight slot.
  delegate.active = 1
  // The masking channel must not let the runner complete: core classifies
  // this as TimeoutError (→ TimedOut), never Completed with garbage.
  let outcome = Ok(@async.with_timeout(200, () => runner())) catch {
    error => Err(error)
  }
  guard outcome is Err(error) else {
    fail("masked cancellation must surface as a timeout, not a completion")
  }
  assert_true(error is @async.TimeoutError)
  // The in-flight slot is released exactly once on the cancelled path.
  assert_eq(delegate.active, 0)
}
