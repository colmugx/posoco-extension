///|
/// WorkspaceFs — the injectable filesystem boundary.
///
/// Methods declare `raise WorkspaceFsError`. Production impls (native via
/// `@fs`, js via node:fs through `#module`) wrap their backing API and
/// convert failures to a typed WorkspaceFsError. Test fakes raise
/// WorkspaceFsError directly.
///
/// The trait is target-agnostic; each backend supplies its own concrete
/// struct (`NativeWorkspaceFs`, `JsWorkspaceFs`) in a target-scoped file.

///|
pub(all) enum WorkspaceFileKind {
  File
  Dir
  Symlink
  Other
} derive(Debug)

///|
pub(all) suberror WorkspaceFsError {
  WorkspaceFsError(String)
} derive(Eq, Debug)

///|
/// Manual Show impl so error messages surface in test/harness output. The
/// derived Debug form prints only the constructor name, hiding the cause.
pub impl Show for WorkspaceFsError with fn to_string(self : WorkspaceFsError) -> String {
  match self {
    WorkspaceFsError(message) => "WorkspaceFsError(" + message + ")"
  }
}

///|
pub(open) trait WorkspaceFs {
  async fn exists(self : Self, path : String) -> Bool raise WorkspaceFsError
  async fn kind(self : Self, path : String, follow_symlink~ : Bool) -> WorkspaceFileKind raise WorkspaceFsError
  async fn read_file(self : Self, path : String) -> String raise WorkspaceFsError
  async fn write_file(self : Self, path : String, content : String) -> Unit raise WorkspaceFsError
  /// Atomically replace `path` with `content`: write a sibling temporary
  /// file first, then rename over the destination. A failure leaves the
  /// previous destination intact. Backends create the file with owner-only
  /// permissions (0o600) because the primary consumer is credential
  /// persistence.
  async fn write_file_atomic(self : Self, path : String, content : String) -> Unit raise WorkspaceFsError
  async fn remove(self : Self, path : String) -> Unit raise WorkspaceFsError
  async fn rename(self : Self, from : String, to_ : String, replace~ : Bool) -> Unit raise WorkspaceFsError
  async fn realpath(self : Self, path : String) -> String raise WorkspaceFsError
  async fn readdir(self : Self, path : String, include_hidden~ : Bool) -> Array[
    String,
  ] raise WorkspaceFsError
  async fn walk(
    self : Self,
    root : String,
    callback : async (String, Array[String]) -> Unit,
  ) -> Unit raise WorkspaceFsError
  async fn mkdir(self : Self, path : String, recursive~ : Bool) -> Unit raise WorkspaceFsError
}

///|
/// Result of reading an optional host-owned file (settings, credentials,
/// profiles). Missing is intentionally distinct from Failed: only an absent
/// optional source may be treated as "not configured". Permission, directory,
/// and other filesystem failures must remain observable at the composition
/// boundary.
pub(all) enum FileReadResult {
  Missing
  Content(String)
  Failed(String)
} derive(Debug)

///|
/// Read `path` through the WorkspaceFs boundary with an explicit
/// missing/failed distinction. `exists` decides Missing; a read failure after
/// the existence check is Failed (never silently Missing).
pub async fn read_file_result(
  fs : &WorkspaceFs,
  path : String,
) -> FileReadResult noraise {
  let present = fs.exists(path) catch {
    WorkspaceFsError::WorkspaceFsError(message) => return Failed(message)
  }
  if !present {
    return Missing
  }
  let content = fs.read_file(path) catch {
    WorkspaceFsError::WorkspaceFsError(message) => return Failed(message)
  }
  Content(content)
}

///|
/// Build the typed WorkspaceFsError used by every backend's failure path.
/// Centralised here so all impls share one error-message convention.
fn fs_err(op : String) -> WorkspaceFsError {
  WorkspaceFsError::WorkspaceFsError("\{op} failed")
}
