///|
/// Native white-box tests for the cancellable shell provider.
///
/// Kill guarantees are observed through file markers the child would write
/// if it survived: `cancel` returns once the escalation is armed (the
/// spawn's `graceful_cancel` handler runs protected and detached, so the
/// task's own `wait` surfaces `WaitedTaskAlreadyCancelled` immediately), and
/// the marker's absence after the grace window proves the child died.
/// Execution drives the public port path end to end: a `PortRuntime`
/// composed over `ShellTools` constructs the `ToolCallContext` and routes
/// `cancel_effects` back to the registered facet.

///|
fn shell_port_runtime(shell : ShellTools) -> @runtime.PortRuntime {
  let no_steps : Array[@posoco.ScriptedModelStep] = []
  @runtime.PortRuntime(
    model=@posoco.ScriptedModel(no_steps) as &@posoco.ModelPort,
    tools=Map::from_array([("bash", shell as &@posoco.ToolProvider)]),
  )
}

///|
fn probe_effect_context(
  effect_value : Int,
  cmd : String,
) -> @runtime.EffectContext {
  {
    effect_id: @kernel.EffectId::{ value: effect_value, },
    owner: @posoco.OwnerId::unchecked("probe"),
    call_id: @kernel.CallId::unchecked("call_probe"),
    tool_name: @kernel.ToolName::unchecked("bash"),
    arguments: Json::object(Map::from_array([("cmd", Json::string(cmd))])),
  }
}

///|
/// Marker file path unique per probe run, under the system temp dir.
fn probe_marker(name : String) -> String {
  "/tmp/cetas_cancel_probe_\{@async.now().to_string()}_\{name}"
}

///|
async fn marker_exists(path : String) -> Bool {
  @fs.exists(path) catch {
    _ => false
  }
}

///|
async fn remove_marker(path : String) -> Unit {
  // The killed child never writes its marker; absence is expected.
  @fs.remove(path) catch {
    _ => ()
  }
}

///|
async test "cancellable shell: normal completion returns output and unregisters" {
  let shell = ShellTools()
  let runtime = shell_port_runtime(shell)
  let marker = probe_marker("t0")
  let ctx = probe_effect_context(40, "echo probe-ok; echo done > \{marker}")
  let outcome = @runtime.Runtime::execute_tool(runtime, ctx)
  guard outcome is @kernel.ToolOutcome::Success(content~, ..) else {
    fail("expected success outcome for a normal command")
  }
  assert_true(content.contains("probe-ok"))
  assert_true(marker_exists(marker))
  assert_false(shell.in_flight.contains(ctx.effect_id.to_int()))
  remove_marker(marker)
  // Settled effect: cancel reports NotPropagated, the registry entry is gone.
  let dispositions = @runtime.Runtime::cancel_effects(
    runtime,
    [ctx.effect_id],
    @kernel.CancelReason::HostRequested(detail=None),
  )
  match dispositions[0] {
    (_, @kernel.NotPropagated) => ()
    _ => fail("expected NotPropagated for a settled effect")
  }
}

///|
async test "cancellable shell: cancel kills a live child and reports Propagated" {
  let shell = ShellTools()
  let runtime = shell_port_runtime(shell)
  let marker = probe_marker("t1")
  let ctx = probe_effect_context(41, "sleep 30; echo finished > \{marker}")
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      let outcome = @runtime.Runtime::execute_tool(runtime, ctx)
      ignore(outcome)
    })
    while !shell.in_flight.contains(ctx.effect_id.to_int()) {
      @async.pause()
    }
    let started = @async.now()
    let dispositions = @runtime.Runtime::cancel_effects(
      runtime,
      [ctx.effect_id],
      @kernel.CancelReason::HostRequested(detail=None),
    )
    let elapsed_ms = (@async.now() - started).to_int()
    assert_eq(dispositions.length(), 1)
    match dispositions[0] {
      (_, @kernel.Propagated) => ()
      _ => fail("expected Propagated disposition")
    }
    // The escalation arms without blocking out the grace window here.
    assert_true(elapsed_ms < shell_cancel_grace_ms)
  })
  // The graceful signal kills `sleep` well inside the grace window, so the
  // marker written only after the full 30s sleep never appears.
  @async.sleep(shell_cancel_grace_ms + 500)
  assert_false(marker_exists(marker))
  assert_false(shell.in_flight.contains(ctx.effect_id.to_int()))
  remove_marker(marker)
}

///|
async test "cancellable shell: signal-immune child is hard-killed after the grace window" {
  let shell = ShellTools()
  let runtime = shell_port_runtime(shell)
  // `trap '' TERM` makes the child ignore the graceful signal; only the
  // post-grace hard kill can stop it.
  let marker = probe_marker("t2")
  let ctx = probe_effect_context(
    42,
    "trap '' TERM; sleep 30; echo survived > \{marker}",
  )
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      let outcome = @runtime.Runtime::execute_tool(runtime, ctx)
      ignore(outcome)
    })
    while !shell.in_flight.contains(ctx.effect_id.to_int()) {
      @async.pause()
    }
    let dispositions = @runtime.Runtime::cancel_effects(
      runtime,
      [ctx.effect_id],
      @kernel.CancelReason::HostRequested(detail=None),
    )
    assert_eq(dispositions.length(), 1)
  })
  // Grace window + margin: the hard kill must have landed by now, so the
  // post-sleep marker never appears.
  @async.sleep(shell_cancel_grace_ms + 1500)
  assert_false(marker_exists(marker))
  remove_marker(marker)
}

///|
async test "cancellable shell: execute offers its facet through the context" {
  let shell = ShellTools()
  let mut registrations = 0
  let ctx : @posoco.ToolCallContext = {
    effect_id: @kernel.EffectId::{ value: 44, },
    call_id: @kernel.CallId::unchecked("call_probe"),
    name: @kernel.ToolName::unchecked("bash"),
    arguments: Json::object(
      Map::from_array([("cmd", Json::string("echo facet"))]),
    ),
    register_cancel: fn(_ : &@posoco.ToolCancellable) {
      registrations = registrations + 1
    },
  }
  let outcome = @posoco.ToolProvider::execute(shell, ctx) catch {
    _ => @kernel.ToolOutcome::Success(content="failed", structured=None)
  }
  guard outcome is @kernel.ToolOutcome::Success(content~, ..) else {
    fail("expected success outcome")
  }
  assert_true(content.contains("facet"))
  assert_eq(registrations, 1)
  assert_false(shell.in_flight.contains(44))
}
