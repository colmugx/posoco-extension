///|
/// session_cwd.mbt — the project directory recorded inside a session's
/// metadata line.
///
/// Bucket directory names hash the cwd irreversibly (`session_<slug>_<hash>`),
/// so a bucket name alone cannot tell a host which project it holds. Stores
/// bound through `of_project` therefore stamp the normalized cwd into every
/// session they persist, which lets `/sessions`-style browsers show — and
/// re-open — sessions from other projects. Sessions written before this
/// contract simply carry no key and stay visible but not cross-resumable.

///|
/// Metadata key holding the normalized project directory of a session.
pub const SESSION_CWD_METADATA_KEY : String = "cetas.cwd"

///|
/// Copy `metadata` and record `cwd`; a `None` cwd (store not bound to a
/// project) returns the metadata untouched, and an existing identical value
/// is kept as-is so re-saving never churns the line.
pub fn metadata_with_cwd(
  metadata : Map[String, Json],
  cwd : String?,
) -> Map[String, Json] {
  let value = match cwd {
    Some(path) if !path.is_empty() => path
    _ => return metadata
  }
  match metadata.get(SESSION_CWD_METADATA_KEY) {
    Some(Json::String(existing)) if existing == value => return metadata
    _ => ()
  }
  let decorated : Map[String, Json] = Map::from_array([])
  for key, item in metadata {
    decorated[key] = item
  }
  decorated[SESSION_CWD_METADATA_KEY] = Json::string(value)
  decorated
}

///|
/// Read the recorded project directory back out of session metadata. Absent or
/// non-string payloads return `None` (legacy journals, stores composed without
/// a project binding) — never a guess derived from the bucket name.
pub fn session_cwd_from_metadata(metadata : Map[String, Json]) -> String? {
  match metadata.get(SESSION_CWD_METADATA_KEY) {
    Some(Json::String(path)) if !path.is_empty() => Some(path)
    _ => None
  }
}
