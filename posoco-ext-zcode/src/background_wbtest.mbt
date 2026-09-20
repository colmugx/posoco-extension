///|
/// Background wiring tests: the delegation itself is faked via the injected
/// runner — no app-server process. Live end-to-end stays behind the
/// ZCODE_EXT_LIVE gate (live_wbtest.mbt).

///|
fn background_call(args? : Array[(String, Json)] = []) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("zcode-test"),
    name: @posoco.ToolName::unchecked("zcode"),
    arguments: Json::object(
      Map::from_array([("task", Json::string("do something"))] + args),
    ),
  }
}

///|
/// Content of the first Success tool result in a transcript, if any.
fn background_success_tool_text(messages : Array[@posoco.Message]) -> String? {
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
fn background_content_text(content : Array[@posoco.Content]) -> String {
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
fn background_user_envelope(messages : Array[@posoco.Message]) -> String? {
  for message in messages {
    match message {
      @posoco.Message::UserMessage(content~) => {
        let text = background_content_text(content)
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
fn background_input_text(messages : Array[@posoco.Message]) -> String {
  let parts : Array[String] = []
  for message in messages {
    let text = match message {
      @posoco.Message::SystemMessage(content~) =>
        background_content_text(content)
      @posoco.Message::UserMessage(content~) => background_content_text(content)
      @posoco.Message::AssistantMessage(content~, ..) =>
        background_content_text(content)
      @posoco.Message::ToolMessage(outcome~, ..) => outcome.summary()
    }
    parts.push(text)
  }
  parts.join("\n")
}

///|
async test "background without composition is an explicit tool error" {
  let tools = zcode_tools()
  let outcome = @posoco.ToolProvider::execute(
    tools,
    "zcode",
    background_call(args=[("background", Json::boolean(true))]),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("composed task capability"))
    _ => fail("expected explicit refusal without composition")
  }
}

///|
test "background with session_id is refused at parse" {
  match
    zcode_parse_args(
      Json::object(
        Map::from_array([
          ("task", Json::string("t")),
          ("background", Json::boolean(true)),
          ("session_id", Json::string("sess_1")),
        ]),
      ),
      default_mode="edit",
    ) {
    Err(message) =>
      assert_true(
        message.contains("foreground-only") && message.contains("1308"),
      )
    Ok(_) => fail("expected background+session_id refusal")
  }
}

///|
async test "background receipt accepted and outcome delivered next turn" {
  let summary = "delegated!\n\nsession_id: sess_child"
  let runs : Ref[Int] = Ref(0)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response(
        "zcode",
        "call-1",
        Json::object(
          Map::from_array([
            ("task", Json::string("do something")),
            ("background", Json::boolean(true)),
          ]),
        ),
      ),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("receipt ok")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("outcome seen")),
  ])
  let store = @posoco.RecordingSessionStore()
  let ext = zcode_ext(
    run=Some(fn(_args : ZcodeTaskArgs) {
      runs.val = runs.val + 1
      summary
    }),
  )
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store]),
      ext as &@posoco.Extension,
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
  // Turn 1 ended with a Success receipt and the delegation actually ran.
  assert_eq(runs.val, 1)
  assert_eq(model.call_count(), 3)
  let persisted = (store as &@posoco.SessionStore).load("sess_1")
  guard background_success_tool_text(persisted.messages) is Some(receipt) else {
    fail("expected the receipt as a Success tool result in the transcript")
  }
  assert_true(receipt.contains("background zcode accepted"))
  assert_true(receipt.contains("delegation_id: "))
  // The next same-session turn carried core's delivery envelope with the
  // injected summary as a user message.
  guard background_user_envelope(persisted.messages) is Some(envelope) else {
    fail("expected a [posoco-task-outcome] user envelope in the transcript")
  }
  assert_true(envelope.contains(summary))
  // The outcome reached the model input of the follow-up turn.
  let prompt = background_input_text(model.received_messages[2])
  assert_true(prompt.contains("[posoco-task-outcome id="))
  assert_true(prompt.contains(summary))
}

///|
/// Core's config timeout must survive the delegation runner masking the
/// timeout cancellation as a returned value: the delivered outcome is
/// classified timed out, never completed with the garbage text.
async test "background timeout survives cancellation masked as a return" {
  let summary = "masked garbage"
  let runs : Ref[Int] = Ref(0)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response(
        "zcode",
        "call-1",
        Json::object(
          Map::from_array([
            ("task", Json::string("do something")),
            ("background", Json::boolean(true)),
          ]),
        ),
      ),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("receipt ok")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("outcome seen")),
  ])
  let store = @posoco.RecordingSessionStore()
  let ext = zcode_ext(
    config={ ..zcode_config(), timeout_ms: 150, },
    run=Some(async fn(_args : ZcodeTaskArgs) {
      runs.val = runs.val + 1
      // Core's timeout cancellation aborts the sleep; swallowing it and
      // returning garbage must not read as a completed delegation.
      @async.sleep(60000) catch {
        _error => ()
      }
      summary
    }),
  )
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store]),
      ext as &@posoco.Extension,
    ],
    config=@posoco.tk_config(),
  )
  ignore(
    agent.run_scoped(async fn(agent) {
      ignore(agent.run_turn(@posoco.tk_user_msg("go"), "sess_1"))
      @async.sleep(600)
      ignore(agent.run_turn(@posoco.tk_user_msg("again"), "sess_1"))
    }),
  )
  // The delegation actually started before the timer fired.
  assert_eq(runs.val, 1)
  let persisted = (store as &@posoco.SessionStore).load("sess_1")
  guard background_user_envelope(persisted.messages) is Some(envelope) else {
    fail("expected a [posoco-task-outcome] user envelope in the transcript")
  }
  // The timer's classification won the race with the masked return.
  assert_true(envelope.contains("label=zcode: timed out"))
  assert_true(!envelope.contains(summary))
}
