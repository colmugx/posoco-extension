///|
/// Lexical workspace containment for the `WorkspaceWrite` pre-approval.
/// Pure string math: the call's `path` argument is resolved against the
/// workspace anchor and must stay inside the anchor root. This closes the
/// `..` traversal hole in the permission decision; it is not a sandbox —
/// symlink escapes and on-disk reality remain the tools' own concern (they
/// anchor their IO through the same anchor).

///|
/// Extract the target path of a write-class call. `write` and `edit` carry
/// a `"path"` string; a call without a parseable path cannot be proven
/// in-workspace and stays behind the gate.
fn write_call_path(arguments : Json) -> String? {
  match arguments {
    Object(fields) =>
      match fields.get("path") {
        Some(String(path)) => Some(path)
        _ => None
      }
    _ => None
  }
}

///|
/// Does `path`, resolved against the anchor, stay inside the anchor root?
/// Absolute targets under a process-relative (relative) root cannot be
/// proven inside and are refused — the gate asks instead.
fn path_inside_workspace(
  anchor : @devkit.WorkspaceAnchor,
  path : String,
) -> Bool {
  let root = anchor.root
  if path.has_prefix("/") && !root.has_prefix("/") {
    return false
  }
  let resolved = anchor.resolve(path)
  if root == "." {
    // Relative root: containment means the normalized path does not climb
    // above the launch directory.
    !(resolved == ".." || resolved.has_prefix("../"))
  } else {
    resolved == root || resolved.has_prefix(root + "/")
  }
}

///|
/// Whether the `WorkspaceWrite` pre-approval covers this call: an anchor
/// must be wired and the write's target path must resolve inside it.
fn PermissionPolicy::workspace_write_covers(
  self : PermissionPolicy,
  effective : @posoco.ToolCall,
) -> Bool {
  let anchor = match self.workspace {
    Some(anchor) => anchor
    None => return false
  }
  match write_call_path(effective.arguments) {
    Some(path) => path_inside_workspace(anchor, path)
    None => false
  }
}
