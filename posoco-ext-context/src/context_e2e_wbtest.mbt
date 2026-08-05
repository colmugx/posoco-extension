///|

///|
async test "e2e: context contributor injects <cetas-context> into model request" {
  // 1. Build a bundle with a known ancestor doc.
  let bundle : ContextBundle = {
    global: None,
    ancestors: [
      {
        path: "/repo/AGENTS.md",
        content: "Build with: make test\nNever commit on main.",
      },
    ],
    warnings: [],
  }
  let contributor = ContextPromptContributor::new(bundle~)
  // 2. ScriptedModel: respond with a plain stop, capture received messages.
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let observer = @posoco.RecordingObserver::RecordingObserver()
  // 3. Wire a real Agent. The context contributor goes into prompt_contributors;
  //    Agent synthesizes a SystemPromptHook automatically.
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(id="io", sessions=[store], observers=[observer], prompt_contributors=[
        contributor as &@posoco.SystemPromptContributor,
      ]),
    ],
    config=@posoco.tk_config(),
  )
  // 4. Run one turn.
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "s1"))
  // 5. Inspect what the model received.
  assert_true(model.received_messages.length() > 0)
  let msgs = model.received_messages[0]
  assert_true(msgs.length() > 0)
  match msgs[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content {
        [@posoco.Content::Text(t), ..] => {
          // The <cetas-context> envelope is present.
          assert_true(t.contains("<cetas-context "))
          assert_true(t.contains("type=\"project_instructions\""))
          assert_true(t.contains("trust=\"false\""))
          assert_true(t.contains("source=\"/repo/AGENTS.md\""))
          assert_true(t.contains("</cetas-context>"))
          // The actual AGENTS.md content survived into the request.
          assert_true(t.contains("Build with: make test"))
          assert_true(t.contains("Never commit on main."))
          // Agent's auto-synthesized hook uses the manifest id as the
          // section header.
          assert_true(t.contains("io:\n"))
        }
        _ => fail("system message should have text content")
      }
    _ => fail("first message should be a SystemMessage")
  }
}

///|
async test "e2e: empty bundle contributes no system message" {
  // An empty ContextBundle returns "" from system_prompt(), which
  // SystemPromptHook::assemble silently skips. The model should still
  // receive a SystemMessage (base_prompt="" produces an empty leading
  // segment), but it must NOT contain <cetas-context>.
  let bundle = ContextBundle::empty()
  let contributor = ContextPromptContributor::new(bundle~)
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let observer = @posoco.RecordingObserver::RecordingObserver()
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(id="io", sessions=[store], observers=[observer], prompt_contributors=[
        contributor as &@posoco.SystemPromptContributor,
      ]),
    ],
    config=@posoco.tk_config(),
  )
  ignore(agent.run_turn(@posoco.tk_user_msg("hello"), "s1"))
  assert_true(model.received_messages.length() > 0)
  let msgs = model.received_messages[0]
  // SystemMessage exists (base_prompt="" still produces one), but no envelope.
  match msgs[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content {
        [@posoco.Content::Text(t), ..] =>
          assert_false(t.contains("<cetas-context"))
        _ => ()
      }
    _ => ()
  }
}
