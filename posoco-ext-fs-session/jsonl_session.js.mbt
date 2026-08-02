///|
/// jsonl_session.js.mbt — JS target (bun runtime) implementation.
///
/// Uses Bun's global APIs (`Bun.file`, `Bun.write`). Bun.write auto-creates
/// parent directories, so no explicit mkdir is needed. Bun is a
/// global object under bun, so `extern "js" fn ... = #| () => Bun.xxx()`
/// works without any require/import. We deliberately do NOT use `node:fs`
/// because the target runtime is bun (per project decision).
///
/// `@js_async.Promise::wait` is an async fn: returns the fulfilled value
/// directly, and raises on rejection. Catch rejections with `try { ... }
/// catch { _ => ... }` — no `Result` wrapping is needed at the call site.

///|
/// Persistent JSONL-backed session store (bun runtime).
pub(all) struct JsonlSessionStore {
  root_dir : String
}

///|
pub fn JsonlSessionStore::new(root_dir : String) -> JsonlSessionStore {
  { root_dir, }
}

// ---------------------------------------------------------------------------
// Bun FFI bindings. All Bun globals here return Promises (or are sync).
// ---------------------------------------------------------------------------

///|
/// Bun's opaque BunFile handle. We only need `.text()` / `.exists()` on it.
#external
priv type BunFile

///|
/// `Bun.file(path)` returns a BunFile. Synchronous in bun.
extern "js" fn bun_file(path : String) -> BunFile =
  #| (path) => Bun.file(path)

///|
/// `BunFile.prototype.text()` returns Promise<string>.
extern "js" fn BunFile::text(self : BunFile) -> @js_async.Promise[String] =
  #| (file) => file.text()

///|
/// `BunFile.prototype.exists()` returns Promise<boolean>.
extern "js" fn BunFile::exists(self : BunFile) -> @js_async.Promise[Bool] =
  #| (file) => file.exists()

///|
/// `Bun.write(path, data)` returns Promise<number> (bytes written).
extern "js" fn bun_write_string(
  path : String,
  data : String,
) -> @js_async.Promise[Int] =
  #| (path, data) => Bun.write(path, data)

///|
/// SessionStore::load — read JSONL via Bun.file.
///
/// Bun's filesystem API is Promise-based; now that the root `SessionStore`
/// trait is `async fn ... raise SessionError`, the JS target can implement
/// it directly without a blocking bridge.
pub impl @posoco.SessionStore for JsonlSessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session raise @posoco.SessionError {
  let path = jsonl_session_path(self.root_dir, id)
  let file = bun_file(path)
  // exists() on a missing file resolves false (not a rejection).
  let exists = file.exists().wait() catch {
      error =>
        raise @posoco.SessionError::Load(
          "jsonl[js]: exists() rejected for " + path + ": " + error.to_string(),
        )
    }
  if !exists {
    return @posoco.Session::{ messages: [], metadata: Map::from_array([]) }
  }
  let content = file.text().wait() catch {
      error =>
        raise @posoco.SessionError::Load(
          "jsonl[js]: text() rejected for " + path + ": " + error.to_string(),
        )
    }
  match session_from_jsonl(content) {
    Ok(s) => s
    Err(e) => raise e
  }
}

///|
/// SessionStore::save — write JSONL via Bun.write.
pub impl @posoco.SessionStore for JsonlSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  // Bun.write auto-creates parent directories, so no explicit mkdir needed.
  let path = jsonl_session_path(self.root_dir, id)
  let jsonl = session_to_jsonl(session)
  try {
    let _ = bun_write_string(path, jsonl).wait()
  } catch {
    error =>
      raise @posoco.SessionError::Save(
        "jsonl[js]: Bun.write rejected for " + path + ": " + error.to_string(),
      )
  }
}
