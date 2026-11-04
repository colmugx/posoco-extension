///|
/// Agent-level acceptance tests for the PTC advanced runtime. These drive a
/// real kernel turn (`Agent::with_runtime`) through the BunrakuRuntime chain
/// so the nested-dispatch seam is exercised exactly the way a host composes
/// it. They pin the pre-migration behavior of the host-handed provider set:
/// P2 (kernel sub-calls) intentionally changes the failure spelling.

///|
/// Shared fixture: one nested "read" tool owned by a recording provider,
/// plus one "grep" tool that the model can call directly but that is NOT
/// handed to the PTC runtime.

///|
struct KernelNestedProbe {
  read : @tk.RecordingToolProvider
  grep : @tk.RecordingToolProvider
}

///|
fn kernel_nested_defs() -> Array[@kernel.ToolDef] {
  [
    {
      name: @kernel.ToolName::unchecked("read"),
      description: "Read one file",
      input_schema: {
        "type": "object",
        "properties": { "path": { "type": "string" } },
        "required": ["path"],
      },
      owner: @kernel.OwnerId::unchecked("posoco_ext_read"),
      policy: @kernel.ExecutionPolicy::Parallel,
      exposure: @kernel.ToolExposure::Direct,
      provenance: None,
    },
    {
      name: @kernel.ToolName::unchecked("grep"),
      description: "Search files",
      input_schema: { "type": "object" },
      owner: @kernel.OwnerId::unchecked("kernel_grep_probe"),
      policy: @kernel.ExecutionPolicy::Parallel,
      exposure: @kernel.ToolExposure::Direct,
      provenance: None,
    },
  ]
}

///|
fn kernel_nested_probe() -> KernelNestedProbe {
  let defs = kernel_nested_defs()
  let read = @tk.RecordingToolProvider(
    [defs[0]],
    Map::from_array([
      (
        "read",
        @tk.ScriptedToolOutcome::OutcomeOk(
          @kernel.ToolOutcome::Success(
            content="ok",
            structured=Some({ "read": true }),
          ),
        ),
      ),
    ]),
  )
  let grep = @tk.RecordingToolProvider(
    [defs[1]],
    Map::from_array([
      (
        "grep",
        @tk.ScriptedToolOutcome::OutcomeOk(
          @kernel.ToolOutcome::Success(content="ok", structured=None),
        ),
      ),
    ]),
  )
  { read, grep, }
}

///|
fn kernel_agent(
  model : @tk.ScriptedModel,
  probe : KernelNestedProbe,
) -> @posoco.Agent raise @posoco.CompositionError {
  // Target-contract composition: every tool (run_code included) is a
  // manifest registration, so the kernel's operation capture holds fixed
  // bindings for all of them; no name routing and no host-handed providers.
  let presentation = @posoco-ext-bunraku.BunrakuExtension()
  let base = @runtime.PortRuntime(model=model as &@posoco.ModelPort)
  let ptc_runtime = @posoco-ext-bunraku.BunrakuRuntime(
    fallback=base as &@runtime.Runtime,
    presentation~,
  )
  @posoco.Agent::with_runtime(
    exts=[
      @tk.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      // Manifest ids become ToolDef owners after aggregation, so the read
      // provider must ride an extension whose id is an allowed nested owner.
      @tk.tk_ext(id="posoco_ext_read", tools=[
        probe.read as &@posoco.ToolProvider,
      ]),
      @tk.tk_ext(id="outside_face", tools=[probe.grep as &@posoco.ToolProvider]),
      ptc_runtime.extension(),
    ],
    config=@tk.tk_config(),
    runtime=ptc_runtime as &@runtime.Runtime,
  )
}

///|
/// Pre-migration pin: a kernel turn drives run_code, the guest program
/// reaches the handed-over provider through the scoped dispatch, and the
/// structured guest return rides the tool result back to the model.
async test "kernel turn runs a guest through the scoped nested dispatch" {
  let probe = kernel_nested_probe()
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(
      @tk.tk_tool_call_response("run_code", "call_1", {
        "description": "Read probe via guest",
        "code": (
          #|let value = ctx.call("read", { "path": "probe.txt" })
          #|value
        ),
      }),
    ),
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("done")),
  ])
  let agent = kernel_agent(model, probe) catch {
    error => fail("composition failed: \{error}")
  }
  let result = agent.run_turn(@tk.tk_user_msg("hello"), "session_1")
  assert_eq(result.tool_results.length(), 1)
  guard result.tool_results[0]
    is @kernel.ToolOutcome::Success(structured=Some({ "read": true, .. }), ..) else {
    fail("guest result did not ride the tool outcome")
  }
  assert_eq(probe.read.exec_records().length(), 1)
  assert_eq(probe.grep.exec_records().length(), 0)
}
