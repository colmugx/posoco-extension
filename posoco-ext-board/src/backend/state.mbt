///|
/// Detached committed state for trusted headless integrations. This does not
/// expose the coordinator or grant a mutation bypass; use handle_command for
/// durable changes. Loading/reconciliation errors remain explicit.
///
/// ```mbt check
/// async test {
///   let backend = @backend.BoardBackend()
///   assert_true(backend.state() is Err(_))
/// }
/// ```
pub async fn BoardBackend::state(
  self : BoardBackend,
) -> Result[@domain.BoardStateSnapshot, @coordinator.BoardCoordinatorError] {
  self.coordinator.snapshot()
}
