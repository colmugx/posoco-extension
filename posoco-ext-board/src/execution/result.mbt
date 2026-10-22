///|
priv struct CapturedExecutionResult {
  task_id : String
  attempt_id : String
  execution_id : String
  run : BoardExecutionRun
  text : String
}

///|
/// What a one-shot capture channel accepts. Planning defaults to tool-free;
/// trusted hosts may explicitly opt in after successful tool use.
pub(all) enum ExecutionCaptureStrategy {
  ToolFreeFinal
  FinalAfterSuccessfulTools
} derive(Eq, @debug.Debug)

///|
pub extend ExecutionCaptureStrategy with Eq::{equal, not_equal}

///|
pub extend ExecutionCaptureStrategy with @debug.Debug::{to_repr}

///|
/// Opt-in, single-use in-memory output. It is never part of the execution
/// journal. Consume only after the owner has durably settled that exact run.
pub struct BoardExecutionResultChannel {
  priv max_chars : Int32
  priv mut strategy : ExecutionCaptureStrategy
  priv mut result : CapturedExecutionResult?
}

///|
pub fn BoardExecutionResultChannel::BoardExecutionResultChannel(
  max_chars~ : Int32,
  strategy~ : ExecutionCaptureStrategy = ToolFreeFinal,
) -> BoardExecutionResultChannel {
  { max_chars, strategy, result: None, }
}

///|
/// Change strategy only while no unread result is held; callers must separately
/// ensure the owning adapter is quiescent.
pub fn BoardExecutionResultChannel::set_strategy(
  self : BoardExecutionResultChannel,
  strategy : ExecutionCaptureStrategy,
) -> Bool {
  if self.result is Some(_) {
    return false
  }
  self.strategy = strategy
  true
}

///|
fn BoardExecutionResultChannel::available(
  self : BoardExecutionResultChannel,
) -> Bool {
  self.max_chars > 0 && self.max_chars <= 1048576 && self.result is None
}

///|
fn BoardExecutionResultChannel::capture(
  self : BoardExecutionResultChannel,
  request : BoardExecutionRequest,
  run : BoardExecutionRun,
  result : @posoco.TurnResult,
) -> Bool {
  if !self.available() {
    return false
  }
  if self.strategy is ToolFreeFinal && !result.tool_results.is_empty() {
    return false
  }
  if self.strategy is FinalAfterSuccessfulTools &&
    result.tool_results.any(outcome => outcome.is_failure()) {
    return false
  }
  let content = match result.message {
    @kernel.AssistantMessage(content~, tool_calls=[], finish_reason=Stop, ..) =>
      content
    _ => return false
  }
  let text = StringBuilder()
  let mut length = 0
  for item in content {
    let value = match item {
      @kernel.Text(value) => value
      _ => return false
    }
    if value.length() > self.max_chars - length {
      return false
    }
    length += value.length()
    text.write_string(value)
  }
  if length == 0 {
    return false
  }
  self.result = Some({
    task_id: request.task_id,
    attempt_id: request.attempt_id,
    execution_id: request.execution_id,
    run,
    text: text.to_string(),
  })
  true
}

///|
/// A wrong, incomplete or unresolved binding cannot read or consume output.
/// A successful read consumes it; neither recovery nor an observer can recreate it.
pub fn BoardExecutionResultChannel::take(
  self : BoardExecutionResultChannel,
  binding : BoardExecutionBinding,
) -> String? {
  guard self.result is Some(result) else { return None }
  if binding.phase != Settled ||
    binding.outcome != Some(Completed) ||
    binding.task_id != result.task_id ||
    binding.attempt_id != result.attempt_id ||
    binding.execution_id != result.execution_id ||
    binding.session_id != result.run.session_id ||
    binding.run != Some(result.run) {
    return None
  }
  self.result = None
  Some(result.text)
}

///|
/// Drop ephemeral output when the host abandons a planning result.
pub fn BoardExecutionResultChannel::discard(
  self : BoardExecutionResultChannel,
) -> Unit {
  self.result = None
}
