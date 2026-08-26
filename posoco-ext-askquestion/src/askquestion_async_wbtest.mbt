///|
priv struct ScriptedUi {
  response : @posoco.UiResponse
  mut request_count : Int
  mut last_request : @posoco.UiRequest?
}

///|
fn ScriptedUi::ScriptedUi(response : @posoco.UiResponse) -> ScriptedUi {
  { response, request_count: 0, last_request: None }
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
async test "ask_question_input_returns_text" {
  let ui = ScriptedUi(@posoco.UiResponse::Text("MoonBit"))
  let tools = AskQuestionTools(ui)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    "ask_question",
    ask_call(Json::object({ "question": Json::string("Language?") })),
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
  let tools = AskQuestionTools(ui)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    "ask_question",
    ask_call(
      Json::object({
        "question": Json::string("Choose"),
        "type": Json::string("select"),
        "options": Json::array([Json::string("A"), Json::string("B")]),
        "default_index": Json::number(1.0),
      }),
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
  let tools = AskQuestionTools(ui)
  let outcome = @posoco.ToolProvider::execute(
    tools,
    "ask_question",
    ask_call(Json::object({ "question": Json::string("Continue?") })),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("cancelled"))
    _ => fail("expected cancellation to be recoverable")
  }
}

///|
async test "ask_question_rejects_empty_select_before_ui" {
  let ui = ScriptedUi(@posoco.UiResponse::Selected(0))
  let tools = AskQuestionTools(ui)
  let result : Result[@posoco.ToolOutcome, @posoco.RuntimeError] = Ok(
    @posoco.ToolProvider::execute(
      tools,
      "ask_question",
      ask_call(
        Json::object({
          "question": Json::string("Choose"),
          "type": Json::string("select"),
        }),
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("at least one option"))
    _ => fail("expected invalid select arguments")
  }
  assert_eq(ui.request_count, 0)
}
