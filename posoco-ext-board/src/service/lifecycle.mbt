///|
pub impl @posoco.Extension for BoardWorkflows with fn extension_id(_) {
  "posoco_ext_board"
}

///|
pub impl @posoco.Extension for BoardWorkflows with fn manifest(self) {
  @posoco.ExtensionManifest(
    id="posoco_ext_board",
    commands=[self],
    lifecycle=[self],
    requires=[@posoco.Capability::Ui],
  )
}

///|
pub impl @posoco.Lifecycle for BoardWorkflows with fn on_compose(self, view) {
  if self.directory.trim().is_empty() ||
    self.directory.iter().any(c => c == '\u0000') ||
    !self.policy.spec("configuration", "root").validate() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_board",
      detail="invalid Board workflow directory or bounded policy",
    )
  }
  self.ui = view.ui()
  if self.ui is None {
    raise @posoco.CompositionError::EmptyPort("posoco_ext_board.ui")
  }
}

///|
pub impl @posoco.Lifecycle for BoardWorkflows with fn on_shutdown(self) {
  if !self.shutdown() {
    raise UnresolvedExecution
  }
}

///|
/// A false result retains the journal lock. The client calls one lifecycle
/// barrier, never reproduces this ownership protocol itself.
pub async fn BoardWorkflows::shutdown(
  self : BoardWorkflows,
  timeout_ms~ : Int32 = 5000,
) -> Bool {
  self.closed = true
  self.live.val = false
  self.cancel()
  if timeout_ms <= 0 {
    return false
  }
  @async.protect_from_cancel(() => {
    if self.operation is Some(task) {
      if !settle_operation(task, timeout_ms) {
        self.unresolved = true
        return false
      }
    }
    if self.unresolved {
      return false
    }
    match self.controller {
      Some(controller) =>
        if !controller.quiesce(timeout_ms~) {
          self.unresolved = true
          return false
        }
      None =>
        if self.owner is Some(owner) && !owner.shutdown(timeout_ms~) {
          self.unresolved = true
          return false
        }
    }
    // A timed-out submit may still own a persistence worker. Agent fan-in
    // alone is not proof that this namespace has no durable writer left.
    if self.uncertain ||
      self.controller
      .map(c => {
        let state = c.status()
        state.expansion_phase == Some(@expansion.Uncertain) ||
        state.partial_preparations.any(p => p.uncertain)
      })
      .unwrap_or(false) {
      return false
    }
    self.journal.close() catch {
      _ => return false
    }
    self.board.shutdown() catch {
      _ => return false
    }
    true
  })
}

///|
pub extend BoardWorkflows with @posoco.Extension::{extension_id, manifest}

///|
pub extend BoardWorkflows with @posoco.CommandPort::{commands, invoke}

///|
pub extend BoardWorkflows with @posoco.Lifecycle::{
  on_compose,
  on_start,
  on_shutdown,
}
