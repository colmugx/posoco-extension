///|
/// An ordinary scheduled turn must execute through Posoco's ModelPort and
/// persist through SessionPort, not through a separate model call.
async test "loop command drives real Posoco turn and persisted session" {
  let now = Ref(0L)
  let loop_ext = LoopExtension(
    now_ms=fn() { now.val },
    sleep_ms=async fn(_ : Int32) { @async.sleep(60000) },
  )
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("checked")),
  ])
  let store = @tk.RecordingSessionPort::RecordingSessionPort()
  let agent = @posoco.Agent(
    exts=[
      @tk.tk_ext(id="model", model=Some(model)),
      @tk.tk_ext(id="io", sessions=[store]),
      loop_ext,
    ],
    config=@tk.tk_config(),
    events=@posoco.EventSystem(),
  )
  @async.with_task_group(async fn(group) {
    loop_ext.start(group~, agent~)
    agent.run_scoped(async fn(_agent) {
      agent.set_active_session(Some("s1"))
      loop_ext.set_session("s1")
      let cmd : &@posoco.CommandPort = loop_ext
      let created = cmd.invoke("loop", Json::string("1s check CI"))
      assert_true(created is @posoco.CommandOutcome::Success(..))
      now.val = 1000L
      loop_ext.poll()
      @async.with_timeout(2000, () => {
        while loop_ext.snapshot()[0].run_count < 1 {
          @async.sleep(1)
        }
      })
      assert_eq(model.call_count(), 1)
      assert_eq(store.store["s1"].messages.length(), 2)
      let listed = cmd.invoke("loop", Json::string("list"))
      assert_true(listed is @posoco.CommandOutcome::Success(..))
      let stopped = cmd.invoke("loop", Json::string("stop loop_1"))
      assert_true(stopped is @posoco.CommandOutcome::Success(..))
      loop_ext.shutdown()
    })
  })
}
