///|
fn board_domain_error_code(error : @domain.BoardError) -> String {
  match error {
    RevisionConflict(..) => "revision_conflict"
    TaskMissing(..) => "task_not_found"
    AttemptMissing(..) => "attempt_not_found"
    InvalidTransition(..) => "invalid_transition"
    InvalidAttemptTransition(..) => "invalid_attempt_transition"
    InvalidReviewTransition(..) => "invalid_review_transition"
    DependencyMissing(..) => "dependency_not_found"
    SelfDependency(..) => "self_dependency"
    DuplicateDependency(..) => "duplicate_dependency"
    DependencyCycle(..) => "dependency_cycle"
    DuplicateTask(..) => "duplicate_task"
    DuplicateAttempt(..) => "duplicate_attempt"
    InvalidInput(..) => "invalid_input"
  }
}

///|
fn board_coordinator_error_code(
  error : @coordinator.BoardCoordinatorError,
) -> String {
  match error {
    NotAttached | Initializing => "board_initializing"
    Closed | RestoreFailed(_) => "board_unavailable"
    TimedOut => "board_timeout"
    Rejected(error) => board_domain_error_code(error)
    PersistFailed(_) => "persistence_failed"
    DurabilityUncertain(_) => "durability_uncertain"
  }
}

///|
async fn BoardRuntime::command_revision(self : BoardRuntime) -> Int64? {
  match self.coordinator.revision() {
    Ok(revision) => Some(revision)
    Err(_) => None
  }
}

///|
/// command_id is correlation only, not a durable idempotency key. A lost
/// response does not undo a commit; clients must refresh authoritative state
/// rather than automatically retrying a mutation.
pub async fn BoardRuntime::handle_command(
  self : BoardRuntime,
  wire : @protocol.BoardClientCommand,
) -> @protocol.BoardCommandResult {
  let command = match @protocol.decode_board_command(wire, (self.now_ms)()) {
    Ok(command) => command
    Err(error) =>
      return {
        command_id: wire.command_id,
        accepted: false,
        error: Some(error.code()),
        current_revision: self.command_revision(),
      }
  }
  match self.coordinator.submit(command~) {
    Ok(_) =>
      {
        // on_commit synchronously enqueues every authoritative event before
        // submit completes. This response never enters EventHub history.
        command_id: wire.command_id,
        accepted: true,
        error: None,
        current_revision: Some(wire.expected_revision + 1L),
      }
    Err(error) => {
      let current_revision = match error {
        Rejected(RevisionConflict(actual~, ..)) => Some(actual)
        // Uncertain durability has already reconciled. Query that resolved
        // committed revision, which may include this mutation.
        _ => self.command_revision()
      }
      {
        command_id: wire.command_id,
        accepted: false,
        error: Some(board_coordinator_error_code(error)),
        current_revision,
      }
    }
  }
}
