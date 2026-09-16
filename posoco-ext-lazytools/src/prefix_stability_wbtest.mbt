///|
fn prefix_stability_def(name : String) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(name),
    description: "Deferred test tool",
    input_schema=Json::object({ "type": Json::string("object") }),
    owner=@posoco.OwnerId::unchecked("prefix_stability_test"),
    policy=@posoco.ExecutionPolicy::Parallel,
    provenance=Some("prefix_stability_test"),
  }
}

///|
test "manifest recent-tool views do not rewrite the prompt" {
  let child = @posoco.RecordingToolProvider(
    [prefix_stability_def("webfetch")],
    Map::from_array([]),
  )
  let ext = match LazyTools::build(providers=[child]) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let manifest = ext.manifest()
  assert_eq(manifest.observers.length(), 1)
  assert_eq(manifest.hooks.length(), 1)

  // Feed the manifest observer the same event that the legacy LazyTools
  // observer would use to update its recent-tool window.
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("call-1"),
    name: @posoco.ToolName::unchecked("tool_execute"),
    arguments: Json::object(
      Map::from_array([
        ("tool", Json::string("webfetch")),
        ("arguments", Json::empty_object()),
      ]),
    ),
  }
  manifest.observers[0].on_event(
    @posoco.TurnEvent::ToolCallResult(
      call~,
      result=@posoco.ToolOutcome::Success(content="ok", structured=None),
      is_error=false,
    ),
  )

  let messages : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hello")]),
  ]
  let after = manifest.hooks[0].before_model(messages)
  assert_eq(after, messages)
}

///|
test "stable prompt tells the model to reuse schemas already in history" {
  let child = @posoco.RecordingToolProvider(
    [prefix_stability_def("webfetch")],
    Map::from_array([]),
  )
  let ext = match LazyTools::build(providers=[child]) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let prompt = ext.manifest().prompt_contributors[0].system_prompt()
  assert_true(prompt.contains("schema that is already present"))
  assert_true(prompt.contains("Do not repeat `tool_list`"))
}
