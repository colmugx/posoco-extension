///|
/// list_ids.js.mbt — JS target directory listing for `list_ids`, through
/// node:fs bound with `#module`. A missing root lists no sessions, mirroring
/// load's missing-file semantics; any other readdir failure raises.

///|
#module("node:fs")
extern "js" fn fs_readdir_sync(path : String) -> FixedArray[String] = "readdirSync"

///|
extern "js" fn fs_readdir_envelope(
  readdir : (String) -> FixedArray[String],
  path : String,
) -> String =
  #| (readdir, path) => {
  #|   try { return JSON.stringify({ ok: true, names: readdir(path) }); }
  #|   catch (error) {
  #|     if (error && error.code === "ENOENT") {
  #|       return JSON.stringify({ ok: true, names: [] });
  #|     }
  #|     return JSON.stringify({
  #|       ok: false,
  #|       message: String(error?.message ?? error),
  #|     });
  #|   }
  #| }

///|
/// Directory entries of root_dir: an empty list when the root does
/// not exist; any other readdir failure is a load-side defect.
fn JsonlSessionStore::raw_dir_entries(
  self : JsonlSessionStore,
) -> Array[String] raise @posoco.SessionError {
  let envelope : Json = @json.parse(
    fs_readdir_envelope(fs_readdir_sync, self.root_dir),
  ) catch {
    _ =>
      raise @posoco.SessionError::Load(
        "jsonl[js]: failed to list " + self.root_dir,
      )
  }
  let fields = match envelope {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.SessionError::Load(
        "jsonl[js]: readdir envelope is not an object for " + self.root_dir,
      )
  }
  match (fields.get("ok"), fields.get("names")) {
    (Some(Json::True), Some(Json::Array(items))) => {
      let entries : Array[String] = []
      for item in items {
        if item is Json::String(name) {
          entries.push(name)
        }
      }
      entries
    }
    (Some(Json::False), Some(Json::String(message))) =>
      raise @posoco.SessionError::Load(
        "jsonl[js]: failed to list " + self.root_dir + ": " + message,
      )
    _ =>
      raise @posoco.SessionError::Load(
        "jsonl[js]: readdir envelope malformed for " + self.root_dir,
      )
  }
}
