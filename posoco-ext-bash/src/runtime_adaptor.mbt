///|
// Runtime-seam piece for the shell tool: an effect-execution decorator that
// makes `bash` calls killable mid-flight.
//
// Plain `ToolProvider`s receive no cancel signal (the default runtime reports
// `NotPropagated`), so an aborted turn used to leave the spawned `sh -c`
// child running as an orphan. This decorator owns the shell spawn itself,
// keys the live child by `EffectContext.effect_id` (the Runtime seam's
// cancellation contract), and terminates it through two cooperating paths:
//
//   1. `cancel_effects` — the run loop's graceful abort path: signal the
//      child, wait out a short grace period, then hard-kill. Reports
//      `Propagated` per handled effect id.
//   2. Unwind cleanup — when the effect task itself is torn down (abort
//      watcher or a host-level hard cancel of the turn coroutine), the
//      per-target execute path signals the child from its defer; the
//      registration stays behind so a later `cancel_effects` can escalate.
//
// Everything except the `bash` tool (name match) delegates to the fallback
// runtime. Hosts that do not install this decorator keep the plain
// `ShellTools` provider behaviour unchanged.

///|
/// The one tool this decorator takes over. ps1 (Windows) keeps its plain
/// provider path.
let cancellable_shell_tool_name : String = "bash"

///|
/// Grace window between the interrupt signal and the hard kill, matching the
/// native spawn's `graceful_cancel` timeout so both escalation paths agree.
let shell_cancel_grace_ms : Int = 2000

///|
pub struct CancellableShellRuntime {
  priv fallback : &@runtime.Runtime
  priv anchor : @devkit.WorkspaceAnchor?
  priv in_flight : Map[Int, ShellChildHandle]
}

///|
/// Canonical constructor. `anchor` must match the `ShellTools` instance in
/// the composition so cwd pinning behaves identically.
pub fn CancellableShellRuntime::CancellableShellRuntime(
  fallback~ : &@runtime.Runtime,
  anchor? : @devkit.WorkspaceAnchor? = None,
) -> CancellableShellRuntime {
  { fallback, anchor, in_flight: Map::from_array([]), }
}

///|
/// Map a raised shell invocation error onto the Runtime contract's
/// `RuntimeFailure` shape, mirroring how `PortRuntime` surfaces a plain
/// provider's raise.
fn shell_runtime_failure(error : @posoco.RuntimeError) -> @kernel.ToolOutcome {
  @kernel.ToolOutcome::RuntimeFailure(
    error_category="ToolProviderError",
    message=error.to_string(),
  )
}

///|
pub impl @runtime.Runtime for CancellableShellRuntime with fn call_model(
  self,
  scope,
  messages,
  tool_definitions,
  call_options,
  on_chunk,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.fallback.call_model(
    scope, messages, tool_definitions, call_options, on_chunk,
  )
}

///|
pub impl @runtime.Runtime for CancellableShellRuntime with fn execute_tool(
  self,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  if ctx.tool_name.to_string() == cancellable_shell_tool_name {
    cancellable_shell_execute(self, ctx)
  } else {
    self.fallback.execute_tool(ctx)
  }
}

///|
/// Terminate every registered shell child: signal, wait out the grace
/// period, then hard-kill. Unregistered ids delegate to the fallback
/// runtime, preserving the one-disposition-per-id contract.
pub impl @runtime.Runtime for CancellableShellRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  // Handles whose execute path already completed normally are dropped from
  // the registry; prune stale exited entries left by unwind-only cleanup.
  let stale : Array[Int] = []
  for key, handle in self.in_flight {
    if handle.exited {
      stale.push(key)
    }
  }
  for key in stale {
    self.in_flight.remove(key)
  }
  let dispositions : Array[(@kernel.EffectId, @kernel.CancelDisposition)] = []
  let delegated : Array[@kernel.EffectId] = []
  for effect_id in effect_ids {
    let key = effect_id.to_int()
    match self.in_flight.get(key) {
      Some(handle) => {
        shell_child_interrupt(handle)
        let exited = shell_child_await_exit(handle, shell_cancel_grace_ms + 500)
        if !exited {
          shell_child_hard_kill(handle)
        }
        self.in_flight.remove(key)
        dispositions.push((effect_id, @kernel.Propagated))
      }
      None => delegated.push(effect_id)
    }
  }
  if !delegated.is_empty() {
    for pair in self.fallback.cancel_effects(delegated, reason) {
      dispositions.push(pair)
    }
  }
  dispositions
}

///|
pub impl @runtime.Runtime for CancellableShellRuntime with fn compact(
  self,
  scope,
  messages,
  call_options,
  trigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.fallback.compact(scope, messages, call_options, trigger)
}

///|
pub extend CancellableShellRuntime with @runtime.Runtime::{
  call_model,
  execute_tool,
  cancel_effects,
  compact,
}
