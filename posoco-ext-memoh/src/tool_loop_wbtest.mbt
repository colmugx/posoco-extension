///|
fn memoh_tool_loop_final_text(result : @posoco.TurnResult) -> String {
  match result.message {
    @posoco.Message::AssistantMessage(content~, ..) => {
      let mut text = ""
      for block in content {
        match block {
          @posoco.Content::Text(value) => text = value
          _ => ()
        }
      }
      text
    }
    _ => ""
  }
}

///|
/// Memoh's no-op SessionStore must not erase the in-memory transcript that
/// Posoco carries inside one turn. A real tool round proves the model can see
/// the tool result path and continue to a second model call before anything is
/// durably persisted.
async test "ephemeral Memoh store preserves one-turn tool loop" {
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response(
        "echo",
        "call_1",
        Json::object(Map::from_array([])),
      ),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let outcomes : Map[String, @posoco.ScriptedToolOutcome] = Map::from_array([])
  outcomes["echo"] = @posoco.ScriptedToolOutcome::OutcomeOk(
    @posoco.tk_ok_result("echoed"),
  )
  let tools = @posoco.RecordingToolProvider(
    [@posoco.tk_tool_def("echo", "echo tool")],
    outcomes,
  )
  let memoh = Memoh()
  let agent = @posoco.Agent(
    exts=[
      memoh as &@posoco.Extension,
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="tools", tools=[tools]),
    ],
    config=@posoco.tk_config(),
  )

  let result = agent.run_turn(
    @posoco.tk_user_msg("use echo"),
    "memoh-tool-loop",
  )
  assert_eq(model.call_count(), 2)
  assert_eq(tools.exec_records().length(), 1)
  assert_eq(memoh_tool_loop_final_text(result), "done")

  // Cross-turn durability remains intentionally empty.
  let stored = memoh.load("memoh-tool-loop")
  assert_eq(stored.messages.length(), 0)
  assert_eq(stored.metadata.length(), 0)
}
