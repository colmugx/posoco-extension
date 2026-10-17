///|
/// One explicitly authorized planning turn, driven only through the existing
/// S4A execution owner. The host supplies a dedicated queued Execute Attempt,
/// ephemeral bounded input and the same private result channel as its adapter.
/// This source owns no Agent, scheduler, journal or mutation capability.
pub struct OwnedAgentPlanSource {
  priv owner : @execution.BoardExecutionOwner
  priv channel : @execution.BoardExecutionResultChannel
  priv request : @execution.BoardExecutionRequest
  priv context : @expansion.DynamicPlanContext
  priv authorize : (@expansion.DynamicPlanContext) -> Bool
  priv now_ms : () -> Int64
  priv mut used : Bool
}

///|
pub fn OwnedAgentPlanSource::OwnedAgentPlanSource(
  owner~ : @execution.BoardExecutionOwner,
  channel~ : @execution.BoardExecutionResultChannel,
  request~ : @execution.BoardExecutionRequest,
  context~ : @expansion.DynamicPlanContext,
  now_ms~ : () -> Int64,
  authorize~ : (@expansion.DynamicPlanContext) -> Bool = _ => false,
) -> OwnedAgentPlanSource {
  {
    owner,
    channel,
    request,
    context: {
      ..context,
      permitted_existing_dependencies: context.permitted_existing_dependencies.copy(),
    },
    authorize,
    now_ms,
    used: false,
  }
}

///|
/// UTF-8 byte length computed without materializing anything, matching the
/// decoder's payload bound: `max_payload_bytes` counts bytes, never UTF-16
/// code units, so multibyte input or output cannot slip past the budget.
fn utf8_length(input : String) -> Int32 {
  let len = input.length()
  let mut bytes = 0
  let mut i = 0
  while i < len {
    let unit = input[i]
    if unit < 0x80 {
      bytes += 1
      i += 1
    } else if unit.is_leading_surrogate() &&
      i + 1 < len &&
      input[i + 1].is_trailing_surrogate() {
      bytes += 4
      i += 2
    } else if unit < 0x800 {
      bytes += 2
      i += 1
    } else {
      bytes += 3
      i += 1
    }
  }
  bytes
}

///|
pub impl @expansion.DynamicPlanSource for OwnedAgentPlanSource with fn generate(
  self,
  context,
) {
  let context = {
    ..context,
    permitted_existing_dependencies: context.permitted_existing_dependencies.copy(),
  }
  if self.used ||
    context != self.context ||
    context.workflow_parent != self.request.task_id ||
    context.authorization_id.trim().is_empty() ||
    context.workflow is None ||
    context.workflow is Some("") ||
    context.max_new_tasks <= 0 ||
    context.max_new_edges < 0 ||
    context.max_payload_bytes <= 0 ||
    context.max_payload_bytes > 1048576 ||
    utf8_length(self.request.input) > context.max_payload_bytes ||
    (self.now_ms)() >= context.deadline_ms ||
    !(self.authorize)(context) {
    return Err(@expansion.Denied)
  }
  let timeout = match self.request.timeout_ms {
    Some(timeout) if timeout > 0 &&
      timeout.to_int64() <= context.deadline_ms - (self.now_ms)() => timeout
    _ => return Err(@expansion.Denied)
  }
  self.used = true
  let mut handle : @execution.BoardExecutionHandle? = None
  let mut joined = false
  defer @async.protect_from_cancel(() => {
    if !joined {
      if handle is Some(active) {
        ignore(self.owner.cancel(active.execution_id()))
        ignore(active.wait())
      }
    }
    self.channel.discard()
  })
  let admitted = @async.protect_from_cancel(() => {
    let result = self.owner.execute(
      { ..self.request, timeout_ms: Some(timeout), },
      admission_guard=_ => {
        (self.now_ms)() < context.deadline_ms && (self.authorize)(context)
      },
    )
    if result is Ok(active) {
      handle = Some(active)
    }
    result
  })
  let active = match admitted {
    Ok(active) => active
    Err(_) => return Err(@expansion.Unavailable)
  }
  let binding = active.wait()
  joined = true
  if (self.now_ms)() >= context.deadline_ms || !(self.authorize)(context) {
    return Err(@expansion.Denied)
  }
  let payload = match self.channel.take(binding) {
    Some(payload) => payload
    None => return Err(@expansion.Unavailable)
  }
  if utf8_length(payload) > context.max_payload_bytes {
    return Err(@expansion.Unavailable)
  }
  Ok({ payload, })
}

///|
pub extend OwnedAgentPlanSource with @expansion.DynamicPlanSource::{generate}
