///|
priv struct NoopUi {}

///|
impl @posoco.UiPort for NoopUi with fn ui_descriptor(_self : NoopUi) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for NoopUi with fn render(
  _self : NoopUi,
  _intent : @posoco.UiRender,
) -> Unit {
  ()
}

///|
impl @posoco.UiPort for NoopUi with fn request(
  _self : NoopUi,
  _req : @posoco.UiRequest,
) -> @posoco.UiResponse raise @posoco.UiError {
  @posoco.UiResponse::Cancelled
}

///|
test "ask_question_parses_input_request" {
  let spec = parse_ask_spec(
    Json::object({
      "question": Json::string("Language?"),
      "default": Json::string("MoonBit"),
    }),
  )
  match spec.request() {
    @posoco.UiRequest::Input(prompt~, default~) => {
      assert_eq(prompt, "Language?")
      assert_eq(default, Some("MoonBit"))
    }
    _ => fail("expected input request")
  }
}

///|
test "ask_question_parses_select_and_maps_response" {
  let spec = parse_ask_spec(
    Json::object({
      "question": Json::string("Choose"),
      "type": Json::string("select"),
      "options": Json::array([Json::string("A"), Json::string("B")]),
      "default_index": Json::number(1.0),
    }),
  )
  match spec.request() {
    @posoco.UiRequest::Select(prompt~, options~, default~) => {
      assert_eq(prompt, "Choose")
      assert_eq(options, ["A", "B"])
      assert_eq(default, Some(1))
    }
    _ => fail("expected select request")
  }
  match response_outcome(spec, @posoco.UiResponse::Selected(1)) {
    @posoco.ToolOutcome::Success(content~, ..) => assert_eq(content, "B")
    _ => fail("expected selected value")
  }
}

///|
test "ask_question_maps_cancel_to_recoverable_error" {
  let spec = parse_ask_spec(
    Json::object({ "question": Json::string("Continue?") }),
  )
  match response_outcome(spec, @posoco.UiResponse::Cancelled) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("cancelled"))
    _ => fail("expected tool-reported cancellation")
  }
}

///|
test "ask_question_rejects_empty_select" {
  let result : Result[AskSpec, @posoco.RuntimeError] = Ok(
    parse_ask_spec(
      Json::object({
        "question": Json::string("Choose"),
        "type": Json::string("select"),
      }),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("at least one option"))
    _ => fail("expected invalid select arguments")
  }
}

///|
test "ask_question_manifest_and_policy" {
  let tools = AskQuestionTools(NoopUi::{  })
  let defs = tools.list_tools()
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].name.to_string(), "ask_question")
  assert_true(defs[0].policy is @posoco.ExecutionPolicy::Exclusive)
  let manifest = tools.manifest()
  assert_eq(manifest.id, "posoco_ext_askquestion")
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
}
