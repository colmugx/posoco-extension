///|
/// Trusted headless submission of a typed domain command. The coordinator
/// remains the sole writer and retains optimistic revision and durability
/// semantics. This does not extend the browser command decoder or authorize
/// Agent-generated commands. An uncertain result must be reconciled, not retried.
pub async fn BoardBackend::submit(
  self : BoardBackend,
  command : @domain.BoardCommand,
) -> Result[Array[@domain.BoardEvent], @coordinator.BoardCoordinatorError] {
  self.coordinator.submit(command=command.copy_detached())
}
