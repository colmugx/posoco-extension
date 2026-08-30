///|
/// list_ids.js.mbt — JS target (bun runtime) directory listing for
/// `list_ids`, mirroring the native `raw_dir_entries` through node:fs
/// promises (Bun implements the Node fs API). Entry names are joined with
/// "\n" on the JS side and split back here, keeping the extern surface a
/// plain string.

///|
/// fs.promises.readdir, with ENOENT folded to the empty string (a missing
/// root lists no sessions, mirroring load's missing-file semantics).
extern "js" fn fs_readdir_joined(path : String) -> @js_async.Promise[String] =
  #| (path) => require("node:fs").promises.readdir(path).then(
  #|   (names) => names.join("\n"),
  #|   (error) => {
  #|     if (error && error.code === "ENOENT") { return "" }
  #|     throw error
  #|   },
  #| )

///|
/// Directory entries of root_dir (bun): an empty list when the root does
/// not exist; any other readdir failure is a load-side defect.
async fn JsonlSessionStore::raw_dir_entries(
  self : JsonlSessionStore,
) -> Array[String] raise @posoco.SessionError {
  let joined = fs_readdir_joined(self.root_dir).wait() catch {
    error =>
      raise @posoco.SessionError::Load(
        "jsonl[js]: failed to list " + self.root_dir + ": " + error.to_string(),
      )
  }
  let entries : Array[String] = []
  for piece in joined.split("\n") {
    entries.push(piece.to_owned())
  }
  entries
}
