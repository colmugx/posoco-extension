///|
/// jsonl_session.js.mbt — JS target (bun runtime) implementation.
///
/// Uses Bun's global APIs (`Bun.file`, `Bun.write`). Bun.write auto-creates
/// parent directories, so no explicit mkdir is needed.

///|
/// Persistent JSONL-backed session store (bun runtime).
pub(all) struct JsonlSessionStore {
  root_dir : String
}

///|
pub fn JsonlSessionStore::new(root_dir : String) -> JsonlSessionStore {
  { root_dir, }
}

#external
priv type BunFile

extern "js" fn bun_file(path : String) -> BunFile =
  #| (path) => Bun.file(path)

extern "js" fn BunFile::text(self : BunFile) -> @js_async.Promise[String] =
  #| (file) => file.text()

extern "js" fn BunFile::exists(self : BunFile) -> @js_async.Promise[Bool] =
  #| (file) => file.exists()

extern "js" fn bun_write_string(
  path : String,
  data : String,
) -> @js_async.Promise[Int] =
  #| (path, data) => Bun.write(path, data)

///|
fn js_load_session_path(
  root_dir : String,
  id : String,
) -> String raise @posoco.SessionError {
  match validate_session_id(id) {
    Ok(_) => jsonl_session_path(root_dir, id)
    Err(reason) => raise @posoco.SessionError::Load("jsonl[js]: " + reason)
  }
}

///|
fn js_save_session_path(
  root_dir : String,
  id : String,
) -> String raise @posoco.SessionError {
  match validate_session_id(id) {
    Ok(_) => jsonl_session_path(root_dir, id)
    Err(reason) => raise @posoco.SessionError::Save("jsonl[js]: " + reason)
  }
}

///|
pub impl @posoco.SessionStore for JsonlSessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session raise @posoco.SessionError {
  let path = js_load_session_path(self.root_dir, id)
  let file = bun_file(path)
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
pub impl @posoco.SessionStore for JsonlSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  let path = js_save_session_path(self.root_dir, id)
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
