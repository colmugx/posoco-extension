///|
/// Identity check for trusted host composition. A controller must prepare work
/// on the same authoritative Board that this owner journals and executes.
pub fn BoardExecutionOwner::uses_backend(
  self : BoardExecutionOwner,
  backend : @backend.BoardBackend,
) -> Bool {
  physical_equal(self.backend, backend)
}
