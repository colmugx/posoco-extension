///|
priv struct FactoryAdapter {
  factory : &WorkflowAgentFactory
  slot : Int32
  workflow : Ref[String]
  planning_attempt : Ref[String?]
  live : Ref[Bool]
  authorize : () -> Bool
  channel : @execution.BoardExecutionResultChannel
  leases : Map[Int32, Array[&@posoco.Extension]]
  mut inner : @execution.PosocoBoardExecutionAdapter?
  mut active : Bool
}

///|
impl @execution.BoardExecutionAdapter for FactoryAdapter with fn ready(self) {
  self.live.val &&
  (self.authorize)() &&
  !self.active &&
  self.inner.map(a => a.ready()).unwrap_or(true)
}

///|
impl @execution.BoardExecutionAdapter for FactoryAdapter with fn run(
  self,
  request,
  start,
) {
  if !self.live.val || !(self.authorize)() || self.active {
    return @execution.Failed
  }
  self.active = true
  defer {
    self.active = false
    self.leases.remove(self.slot)
  }
  let purpose = if self.planning_attempt.val == Some(request.attempt_id) {
    Planning
  } else {
    Execution
  }
  let composition = self.factory.prepare({
    purpose,
    workflow_id: self.workflow.val,
    task_id: request.task_id,
    attempt_id: request.attempt_id,
    session_id: request.session_id,
    slot: self.slot,
  }) catch {
    _ => return @execution.Failed
  }
  if !self.live.val {
    return @execution.Cancelled
  }
  // Verification and registration below never await: simultaneous factory
  // completions cannot both claim the same exposed capability reference.
  for ext in composition.extensions {
    let manifest = ext.manifest()
    if !manifest.sessions.is_empty() ||
      !manifest.logs.is_empty() ||
      (purpose == Planning && !manifest.tools.is_empty()) ||
      manifest.id == "posoco_ext_board" {
      return @execution.Failed
    }
    for other in self.leases.values() {
      for installed in other {
        if physical_equal(ext, installed) {
          return @execution.Failed
        }
        for model in manifest.models {
          if installed.manifest().models.any(p => physical_equal(p, model)) {
            return @execution.Failed
          }
        }
      }
    }
  }
  self.leases[self.slot] = composition.extensions.copy()
  let inner = @execution.PosocoBoardExecutionAdapter(
    extensions=() => composition.extensions.copy(),
    config=composition.config,
    available=() => self.live.val && (self.authorize)(),
    result_channel=self.channel,
  )
  self.inner = Some(inner)
  inner.run(request, start)
}
