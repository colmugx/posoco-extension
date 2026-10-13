///|
priv struct ScriptedUi {
  response : @posoco.UiResponse
  mut request_count : Int32
  mut last_request : @posoco.UiRequest?
}

///|
fn ScriptedUi::ScriptedUi(response : @posoco.UiResponse) -> ScriptedUi {
  { response, request_count: 0, last_request: None, }
}

///|
impl @posoco.UiPort for ScriptedUi with fn ui_descriptor(_self : ScriptedUi) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for ScriptedUi with fn render(
  _self : ScriptedUi,
  _intent : @posoco.UiRender,
) -> Unit {
  ()
}

///|
impl @posoco.UiPort for ScriptedUi with fn request(
  self : ScriptedUi,
  req : @posoco.UiRequest,
) -> @posoco.UiResponse raise @posoco.UiError {
  self.request_count = self.request_count + 1
  self.last_request = Some(req)
  self.response
}

///|
fn ask_call(arguments : Json) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("ask-test"),
    name: @posoco.ToolName::unchecked("ask_question"),
    arguments,
  }
}

///|
/// Effect context for provider calls (no-op registrar).
fn test_ctx(call : @posoco.ToolCall) -> @posoco.ToolCallContext {
  {
    effect_id: @kernel.EffectId::{ value: 1, },
    call_id: call.call_id,
    name: call.name,
    arguments: call.arguments,
    register_cancel: fn(_ : &@posoco.ToolCancellable) { () },
  }
}

///|
async test "ask_question_input_returns_text" {
  let ui = ScriptedUi(@posoco.UiResponse::Text("MoonBit"))
  let tools = AskQuestionTools()
  tools.ui = Some(ui as &@posoco.UiPort)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(ask_call(Json::object({ "question": Json::string("Language?") }))),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => assert_eq(content, "MoonBit")
    _ => fail("expected input success")
  }
  assert_eq(ui.request_count, 1)
  match ui.last_request {
    Some(@posoco.UiRequest::Input(prompt~, ..)) =>
      assert_eq(prompt, "Language?")
    _ => fail("expected input request")
  }
}

///|
async test "ask_question_select_returns_selected_value" {
  let ui = ScriptedUi(@posoco.UiResponse::Selected(1))
  let tools = AskQuestionTools()
  tools.ui = Some(ui as &@posoco.UiPort)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      ask_call(
        Json::object({
          "question": Json::string("Choose"),
          "type": Json::string("select"),
          "options": Json::array([Json::string("A"), Json::string("B")]),
          "default_index": Json::number(1.0),
        }),
      ),
    ),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => assert_eq(content, "B")
    _ => fail("expected select success")
  }
}

///|
async test "ask_question_cancel_is_tool_reported_error" {
  let ui = ScriptedUi(@posoco.UiResponse::Cancelled)
  let tools = AskQuestionTools()
  tools.ui = Some(ui as &@posoco.UiPort)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(ask_call(Json::object({ "question": Json::string("Continue?") }))),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_eq(content, "cancelled")
    _ => fail("expected cancellation to be recoverable")
  }
}

///|
async test "ask_question_rejects_empty_select_before_ui" {
  let ui = ScriptedUi(@posoco.UiResponse::Selected(0))
  let tools = AskQuestionTools()
  tools.ui = Some(ui as &@posoco.UiPort)
  let result : Result[@posoco.ToolOutcome, @posoco.RuntimeError] = Ok(
    @posoco.ToolProvider::execute(
      tools,
      test_ctx(
        ask_call(
          Json::object({
            "question": Json::string("Choose"),
            "type": Json::string("select"),
          }),
        ),
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("requires options"))
    _ => fail("expected invalid select arguments")
  }
  assert_eq(ui.request_count, 0)
}

///|
priv struct ScriptedEndpoint {
  response : @posoco.UiResponse
  error : QuestionError?
  mut request_count : Int32
  mut last_origin : String
  mut last_request : @posoco.UiRequest?
}

///|
fn ScriptedEndpoint::ScriptedEndpoint(
  response~ : @posoco.UiResponse,
  error~ : QuestionError? = None,
) -> ScriptedEndpoint {
  { response, error, request_count: 0, last_origin: "", last_request: None, }
}

///|
impl QuestionEndpoint for ScriptedEndpoint with fn request(
  self : ScriptedEndpoint,
  origin_call~ : String,
  req~ : @posoco.UiRequest,
) -> @posoco.UiResponse raise QuestionError {
  self.request_count = self.request_count + 1
  self.last_origin = origin_call
  self.last_request = Some(req)
  match self.error {
    Some(error) => raise error
    None => self.response
  }
}

///|
fn ask_child_call(arguments : Json) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("ask-child-test"),
    name: @posoco.ToolName::unchecked("ask_question_child"),
    arguments,
  }
}

///|
async test "ask_question_child_input_returns_text_with_origin" {
  let endpoint = ScriptedEndpoint(response=@posoco.UiResponse::Text("42"))
  let tools = AskQuestionTools::for_parent(
    endpoint=endpoint as &QuestionEndpoint,
  )
  let outcome = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      ask_child_call(Json::object({ "question": Json::string("Meaning?") })),
    ),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => assert_eq(content, "42")
    _ => fail("expected parent-face input success")
  }
  assert_eq(endpoint.request_count, 1)
  assert_eq(endpoint.last_origin, "ask-child-test")
  match endpoint.last_request {
    Some(@posoco.UiRequest::Input(prompt~, ..)) => assert_eq(prompt, "Meaning?")
    _ => fail("expected input request")
  }
}

///|
async test "ask_question_child_timeout_and_cancel_are_recoverable" {
  let timeout = ScriptedEndpoint(
    response=@posoco.UiResponse::Text("never"),
    error=Some(QuestionError::TimedOut),
  )
  let tools = AskQuestionTools::for_parent(
    endpoint=timeout as &QuestionEndpoint,
  )
  match
    @posoco.ToolProvider::execute(
      tools,
      test_ctx(ask_child_call(Json::object({ "question": Json::string("Q?") }))),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, structured~) => {
      assert_eq(content, "answer timed out")
      match structured {
        Some(json) =>
          assert_eq(json.stringify().contains("\"timed_out\":true"), true)
        None => fail("expected structured timeout flag")
      }
    }
    _ => fail("expected timeout to be recoverable")
  }
  let cancelled = ScriptedEndpoint(
    response=@posoco.UiResponse::Text("never"),
    error=Some(QuestionError::Cancelled),
  )
  let cancelled_tools = AskQuestionTools::for_parent(
    endpoint=cancelled as &QuestionEndpoint,
  )
  match
    @posoco.ToolProvider::execute(
      cancelled_tools,
      test_ctx(ask_child_call(Json::object({ "question": Json::string("Q?") }))),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_eq(content, "cancelled")
    _ => fail("expected cancellation to be recoverable")
  }
}

///|
async test "ask_question_faces_reject_cross_face_names" {
  let endpoint = ScriptedEndpoint(response=@posoco.UiResponse::Text("42"))
  let parent_tools = AskQuestionTools::for_parent(
    endpoint=endpoint as &QuestionEndpoint,
  )
  let result : Result[@posoco.ToolOutcome, @posoco.RuntimeError] = Ok(
    @posoco.ToolProvider::execute(
      parent_tools,
      test_ctx(ask_call(Json::object({ "question": Json::string("Q?") }))),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("ask_question"))
    _ => fail("expected parent face to reject the human tool name")
  }
  let ui = ScriptedUi(@posoco.UiResponse::Text("42"))
  let human_tools = AskQuestionTools()
  human_tools.ui = Some(ui as &@posoco.UiPort)
  let result : Result[@posoco.ToolOutcome, @posoco.RuntimeError] = Ok(
    @posoco.ToolProvider::execute(
      human_tools,
      test_ctx(ask_child_call(Json::object({ "question": Json::string("Q?") }))),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(_)) => ()
    _ => fail("expected human face to reject the parent tool name")
  }
}
