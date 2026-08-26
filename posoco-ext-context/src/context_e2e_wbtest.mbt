///|

///|
async test "e2e: context contributor injects configured envelope into model request" {
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
  let contributor = ContextPromptContributor(bundle~, ns="posoco")
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
  assert_true(msgs.length() > 0)
  match msgs[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content {
        [@posoco.Content::Text(t), ..] => {
          assert_true(t.contains("<posoco-context "))
          assert_true(t.contains("type=\"project_instructions\""))
          assert_true(t.contains("trust=\"false\""))
          assert_true(t.contains("source=\"/repo/AGENTS.md\""))
          assert_true(t.contains("</posoco-context>"))
          assert_true(t.contains("Build with: make test"))
          assert_true(t.contains("Never commit on main."))
          assert_true(t.contains("io:\n"))
        }
        _ => fail("system message should have text content")
      }
    _ => fail("first message should be a SystemMessage")
  }
}

///|
async test "e2e: empty bundle contributes no configured envelope" {
  let bundle = ContextBundle::empty()
  let contributor = ContextPromptContributor(bundle~, ns="posoco")
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
  match msgs[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content {
        [@posoco.Content::Text(t), ..] =>
          assert_false(t.contains("<posoco-context"))
        _ => ()
      }
    _ => ()
  }
}
