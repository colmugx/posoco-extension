///|
struct ToolCaptureAgent {
  mut calls : Int32
  mut executions : Int32
}

///|
impl @posoco.Extension for ToolCaptureAgent with fn extension_id(_) {
  "tool-capture-agent"
}

///|
impl @posoco.Extension for ToolCaptureAgent with fn manifest(self) {
  @posoco.ExtensionManifest(id="tool-capture-agent", models=[self], tools=[self])
}

///|
impl @posoco.ModelPort for ToolCaptureAgent with fn provider_config(_) {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for ToolCaptureAgent with fn chat(
  self,
  _scope,
  messages,
  _tools,
  _options,
  _stream,
) {
  self.calls += 1
  let completion = if self.calls == 1 {
    @kernel.Completion(
      content=[],
      tool_calls=[
        {
          call_id: @kernel.CallId::unchecked("capture-call"),
          name: @kernel.ToolName::unchecked("capture_tool"),
          arguments: {},
        },
      ],
      reasoning=None,
      finish_reason=@kernel.ToolCalls,
      usage=None,
    )
  } else {
    @kernel.Completion(
      content=[@kernel.Text("final after legitimate tool")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@kernel.Stop,
      usage=None,
    )
  }
  { completion, processed_messages: messages.to_owned(), }
}

///|
impl @posoco.ModelPort for ToolCaptureAgent with fn compact(_, _, _, _, _, _) {
  raise @posoco.ModelError::Transport("unexpected compact")
}

///|
impl @posoco.ToolProvider for ToolCaptureAgent with fn list_tools(_) {
  [
    @kernel.ToolDef(
      name=@kernel.ToolName::unchecked("capture_tool"),
      description="deterministic capture fixture",
      input_schema={},
      owner=@kernel.OwnerId::unchecked("capture-test"),
      policy=@kernel.ExecutionPolicy::Sequential,
      provenance=None,
    ),
  ]
}

///|
impl @posoco.ToolProvider for ToolCaptureAgent with fn execute(self, _ctx) {
  self.executions += 1
  @kernel.Success(content="tool completed", structured=None)
}

///|
async test "explicit successful-tool capture is one-shot exact-binding and default stays tool-free" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let model : ToolCaptureAgent = { calls: 0, executions: 0, }
    let channel = @execution.BoardExecutionResultChannel(
      max_chars=128,
      strategy=@execution.FinalAfterSuccessfulTools,
    )
    let driver = @execution.PosocoBoardExecutionAdapter(
      extensions=() => [model],
      config=@posoco.agent_config(max_tool_rounds=Some(1)),
      result_channel=channel,
    )
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=@execution.MemoryBoardExecutionStore(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let binding = owner.execute(request()).unwrap().wait()
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Completed))
    assert_eq(model.calls, 2)
    assert_eq(model.executions, 1)
    assert_eq(channel.take({ ..binding, attempt_id: "other", }), None)
    assert_eq(channel.take(binding), Some("final after legitimate tool"))
    assert_eq(channel.take(binding), None)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}
