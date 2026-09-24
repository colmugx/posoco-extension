///|
/// Native white-box tests for the cancellable shell runtime.
///
/// Kill guarantees are observed through file markers the child would write
/// if it survived: `cancel_effects` returns once the escalation is armed
/// (the spawn's `graceful_cancel` handler runs protected and detached, so
/// the task's own `wait` surfaces `TaskCancelled` immediately), and the
/// marker's absence after the grace window proves the child died.

///|
/// Minimal fallback runtime recording the calls it receives.
struct RecordingFallbackRuntime {
  execute_calls : Array[String]
  mut cancel_calls : Int
}

///|
pub impl @runtime.Runtime for RecordingFallbackRuntime with fn call_model(
  _self,
  _scope,
  _messages,
  _tool_definitions,
  _call_options,
  _on_chunk,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  Err(
    @kernel.ModelFailure::Runtime(
      reason="recording fallback never serves models",
    ),
  )
}

///|
pub impl @runtime.Runtime for RecordingFallbackRuntime with fn execute_tool(
  self,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  self.execute_calls.push(ctx.tool_name.to_string())
  @kernel.ToolOutcome::RuntimeFailure(
    error_category="ToolProviderError",
    message="recording fallback executes nothing",
  )
}

///|
pub impl @runtime.Runtime for RecordingFallbackRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  _reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.cancel_calls = self.cancel_calls + 1
  effect_ids.map(id => (id, @kernel.NotPropagated))
}

///|
pub impl @runtime.Runtime for RecordingFallbackRuntime with fn compact(
  _self,
  _scope,
  _messages,
  _call_options,
  _trigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  Err(@kernel.ModelFailure::Runtime(reason="recording fallback never compacts"))
}

///|
pub extend RecordingFallbackRuntime with @runtime.Runtime::{
  call_model,
  execute_tool,
  cancel_effects,
  compact,
}

///|
fn probe_effect_context(
  effect_value : Int,
  cmd : String,
  tool_name? : String = "bash",
) -> @runtime.EffectContext {
  {
    effect_id: @kernel.EffectId::{ value: effect_value, },
    owner: @posoco.OwnerId::unchecked("probe"),
    call_id: @kernel.CallId::unchecked("call_probe"),
    tool_name: @kernel.ToolName::unchecked(tool_name),
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
  let fallback : RecordingFallbackRuntime = {
    execute_calls: [],
    cancel_calls: 0,
  }
  let runtime = CancellableShellRuntime(fallback=fallback as &@runtime.Runtime)
  let marker = probe_marker("t0")
  let ctx = probe_effect_context(40, "echo probe-ok; echo done > \{marker}")
  let outcome = @runtime.Runtime::execute_tool(
    runtime as &@runtime.Runtime,
    ctx,
  )
  guard outcome is @kernel.ToolOutcome::Success(content~, ..) else {
    fail("expected success outcome for a normal command")
  }
  assert_true(content.contains("probe-ok"))
  assert_true(marker_exists(marker))
  assert_false(runtime.in_flight.contains(ctx.effect_id.to_int()))
  remove_marker(marker)
  // Shell effects never reach the fallback.
  assert_eq(fallback.execute_calls.length(), 0)
}

///|
async test "cancellable shell: cancel_effects kills a live child and reports Propagated" {
  let fallback : RecordingFallbackRuntime = {
    execute_calls: [],
    cancel_calls: 0,
  }
  let runtime = CancellableShellRuntime(fallback=fallback as &@runtime.Runtime)
  let marker = probe_marker("t1")
  let ctx = probe_effect_context(41, "sleep 30; echo finished > \{marker}")
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      let outcome = @runtime.Runtime::execute_tool(
        runtime as &@runtime.Runtime,
        ctx,
      )
      ignore(outcome)
    })
    while !runtime.in_flight.contains(ctx.effect_id.to_int()) {
      @async.pause()
    }
    let started = @async.now()
    let dispositions = @runtime.Runtime::cancel_effects(
      runtime as &@runtime.Runtime,
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
  assert_false(runtime.in_flight.contains(ctx.effect_id.to_int()))
  remove_marker(marker)
}

///|
async test "cancellable shell: signal-immune child is hard-killed after the grace window" {
  let fallback : RecordingFallbackRuntime = {
    execute_calls: [],
    cancel_calls: 0,
  }
  let runtime = CancellableShellRuntime(fallback=fallback as &@runtime.Runtime)
  // `trap '' TERM` makes the child ignore the graceful signal; only the
  // post-grace hard kill can stop it.
  let marker = probe_marker("t2")
  let ctx = probe_effect_context(
    42,
    "trap '' TERM; sleep 30; echo survived > \{marker}",
  )
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      let outcome = @runtime.Runtime::execute_tool(
        runtime as &@runtime.Runtime,
        ctx,
      )
      ignore(outcome)
    })
    while !runtime.in_flight.contains(ctx.effect_id.to_int()) {
      @async.pause()
    }
    let dispositions = @runtime.Runtime::cancel_effects(
      runtime as &@runtime.Runtime,
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
async test "cancellable shell: non-shell effects delegate to the fallback" {
  let fallback : RecordingFallbackRuntime = {
    execute_calls: [],
    cancel_calls: 0,
  }
  let runtime = CancellableShellRuntime(fallback=fallback as &@runtime.Runtime)
  let ctx = probe_effect_context(43, "x", tool_name="read")
  let outcome = @runtime.Runtime::execute_tool(
    runtime as &@runtime.Runtime,
    ctx,
  )
  guard outcome
    is @kernel.ToolOutcome::RuntimeFailure(
      error_category="ToolProviderError",
      ..
    ) else {
    fail("expected delegated failure from the fallback")
  }
  assert_eq(fallback.execute_calls, ["read"])
}
