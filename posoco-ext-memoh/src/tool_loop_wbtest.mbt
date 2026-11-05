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
/// Memoh's no-op SessionPort must not erase the in-memory transcript that
/// Posoco carries inside one turn. A real tool round proves the model can see
/// the tool result path and continue to a second model call before anything is
/// durably persisted.
async test "ephemeral Memoh store preserves one-turn tool loop" {
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(
      @tk.tk_tool_call_response(
        "echo",
        "call_1",
        Json::object(Map::from_array([])),
      ),
    ),
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("done")),
  ])
  let outcomes : Map[String, @tk.ScriptedToolOutcome] = Map::from_array([])
  outcomes["echo"] = @tk.ScriptedToolOutcome::OutcomeOk(
    @tk.tk_ok_result("echoed"),
  )
  let tools = @tk.RecordingToolProvider(
    [@tk.tk_tool_def("echo", "echo tool")],
    outcomes,
  )
  let memoh = Memoh()
  let agent = @posoco.Agent(
    exts=[
      memoh as &@posoco.Extension,
      @tk.tk_ext(id="model", model=Some(model)),
      @tk.tk_ext(id="tools", tools=[tools]),
    ],
    config=@tk.tk_config(),
    events=@posoco.EventSystem(),
  )

  let result = agent.run_turn(@tk.tk_user_msg("use echo"), "memoh-tool-loop")
  assert_eq(model.call_count(), 2)
  assert_eq(tools.exec_records().length(), 1)
  assert_eq(memoh_tool_loop_final_text(result), "done")

  // Cross-turn durability remains intentionally empty.
  let stored = memoh.load("memoh-tool-loop")
  assert_eq(stored.messages.length(), 0)
  assert_eq(stored.metadata.length(), 0)
}
