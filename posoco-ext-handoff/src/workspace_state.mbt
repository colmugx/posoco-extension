///|
/// Small host-pushed implementation of `HandoffWorkspaceProbe`.
///
/// Products that already know project/VCS facts can update this value without
/// teaching the handoff extension how to execute Git or inspect another port.
pub struct HandoffWorkspaceState {
  mut workspace : WorkspaceSnapshot
}

///|
fn copy_workspace(workspace : WorkspaceSnapshot) -> WorkspaceSnapshot {
  {
    root: workspace.root,
    branch: workspace.branch,
    head: workspace.head,
    changes: workspace.changes.copy(),
  }
}

///|
pub fn HandoffWorkspaceState::HandoffWorkspaceState(
  root : String,
  branch? : String? = None,
  head? : String? = None,
  changes? : Array[WorkspaceChange] = [],
) -> HandoffWorkspaceState {
  { workspace: { root, branch, head, changes: changes.copy() } }
}

///|
pub fn HandoffWorkspaceState::current(
  self : HandoffWorkspaceState,
) -> WorkspaceSnapshot {
  copy_workspace(self.workspace)
}

///|
pub fn HandoffWorkspaceState::replace(
  self : HandoffWorkspaceState,
  workspace : WorkspaceSnapshot,
) -> Unit {
  self.workspace = copy_workspace(workspace)
}

///|
pub fn HandoffWorkspaceState::set_branch(
  self : HandoffWorkspaceState,
  branch : String?,
) -> Unit {
  self.workspace = { ..self.workspace, branch, }
}

///|
pub fn HandoffWorkspaceState::set_head(
  self : HandoffWorkspaceState,
  head : String?,
) -> Unit {
  self.workspace = { ..self.workspace, head, }
}

///|
pub fn HandoffWorkspaceState::set_changes(
  self : HandoffWorkspaceState,
  changes : Array[WorkspaceChange],
) -> Unit {
  self.workspace = { ..self.workspace, changes: changes.copy() }
}

///|
pub impl HandoffWorkspaceProbe for HandoffWorkspaceState with fn snapshot(
  self : HandoffWorkspaceState,
  cwd : String,
) -> Result[WorkspaceSnapshot, String] {
  let workspace = self.current()
  if workspace.root.length() == 0 {
    Err("handoff workspace root is empty")
  } else if cwd.length() == 0 {
    Err("handoff cwd is empty")
  } else {
    Ok(workspace)
  }
}
