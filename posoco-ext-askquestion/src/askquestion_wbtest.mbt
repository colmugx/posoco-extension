///|
#warnings("-struct_never_constructed")
priv struct NoopUi {}

///|
#warnings("-unused_value")
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
test "ask_question_manifest_and_policy" {
  let tools = AskQuestionTools()
  let defs = @posoco.ToolProvider::list_tools(tools)
  assert_eq(defs.length(), 2)
  assert_eq(defs[0].name.to_string(), "ask_question")
  assert_true(defs[0].policy is @posoco.ExecutionPolicy::Exclusive)
  assert_eq(defs[1].name.to_string(), "notify_user")
  assert_true(defs[1].policy is @posoco.ExecutionPolicy::Sequential)
  let manifest = tools.manifest()
  assert_eq(manifest.id, "posoco_ext_askquestion")
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 0)
  assert_eq(manifest.requires, [
    @posoco.Capability::Ui,
    @posoco.Capability::Wakeup,
  ])
  assert_eq(manifest.lifecycle.length(), 1)
}

///|
test "ask_question_schema_uses_enum_for_prompt_type" {
  let schema = ask_question_schema().stringify()
  assert_true(schema.contains("\"enum\""))
  assert_true(schema.contains("\"input\""))
  assert_true(schema.contains("\"confirm\""))
  assert_true(schema.contains("\"select\""))
}

///|
test "ask_question_parent_face_names_tool_ask_question_child" {
  let endpoint = ScriptedEndpoint(response=@posoco.UiResponse::Text("ok"))
  let tools = AskQuestionTools::for_parent(
    endpoint=endpoint as &QuestionEndpoint,
  )
  let defs = @posoco.ToolProvider::list_tools(tools)
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].name.to_string(), "ask_question_child")
  assert_true(defs[0].description.contains("parent agent"))
  assert_true(defs[0].policy is @posoco.ExecutionPolicy::Exclusive)
  let manifest = tools.manifest()
  assert_eq(manifest.requires, [])
  assert_true(
    @posoco.SystemPromptContributor::system_prompt(tools).contains(
      "ask_question_child",
    ),
  )
  assert_eq(defs[0].input_schema.stringify().contains("parent agent"), true)
}

///|
test "select_ui_options_appends_escape_slot_once" {
  assert_eq(select_ui_options(["A", "B"]), ["A", "B", OTHER_ANSWER_OPTION])
  assert_eq(select_ui_options(["A", OTHER_ANSWER_OPTION]), [
    "A",
    OTHER_ANSWER_OPTION,
  ])
}
