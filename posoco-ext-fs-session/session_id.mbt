///|
/// Session identifiers are used as filename stems by JsonlSessionStore.
/// Keep validation at the storage boundary so callers cannot escape root_dir
/// with relative paths on native or Bun targets.
pub fn validate_session_id(id : String) -> Result[Unit, String] {
  if id.length() == 0 {
    return Err("session id must not be empty")
  }
  if id == "." || id == ".." {
    return Err("session id must not be a relative path segment")
  }
  if id.contains("/") || id.contains("\\") {
    return Err("session id must not contain path separators")
  }
  Ok(())
}
