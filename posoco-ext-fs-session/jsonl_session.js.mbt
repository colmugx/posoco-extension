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
pub fn JsonlSessionStore::JsonlSessionStore(
  root_dir : String,
) -> JsonlSessionStore {
  { root_dir, }
}

///|
#external
priv type BunFile

///|
extern "js" fn bun_file(path : String) -> BunFile =
  #| (path) => Bun.file(path)

///|
extern "js" fn BunFile::text(self : BunFile) -> @js_async.Promise[String] =
  #| (file) => file.text()

///|
extern "js" fn BunFile::exists(self : BunFile) -> @js_async.Promise[Bool] =
  #| (file) => file.exists()

///|
extern "js" fn bun_write_string(
  path : String,
  data : String,
) -> @js_async.Promise[Int] =
  #| (path, data) => Bun.write(path, data)

///|
/// fs.promises.appendFile — appends data, creating the file if missing (but
/// not parent directories). Bun implements the Node fs promises API; the
/// resolved byte count keeps the Promise[Int] shape of `bun_write_string`.
extern "js" fn fs_append_file(
  path : String,
  data : String,
) -> @js_async.Promise[Int] =
  #| (path, data) => require("node:fs").promises.appendFile(path, data).then(() => data.length)

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
    return @posoco.Session::{ messages: [], metadata: Map::from_array([]), }
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

///|
/// SessionStore::append_messages — mirror of the native implementation: a
/// missing file gets a full JSONL write (metadata + messages) so the first
/// append behaves like a save; an existing file only receives the new message
/// lines. `from_index` is unused, matching native.
pub impl @posoco.SessionStore for JsonlSessionStore with fn append_messages(
  self,
  id : String,
  from_index : Int,
  messages : ArrayView[@posoco.Message],
) -> Unit raise @posoco.SessionError {
  let _ = from_index
  let path = js_save_session_path(self.root_dir, id)
  let exists = bun_file(path).exists().wait() catch {
      error =>
        raise @posoco.SessionError::Save(
          "jsonl[js]: exists() rejected for " + path + ": " + error.to_string(),
        )
    }
  if !exists {
    // First persistence for this id: Bun.write creates parent directories.
    let session : @posoco.Session = {
      messages: messages.to_owned(),
      metadata: Map::from_array([]),
    }
    try {
      let _ = bun_write_string(path, session_to_jsonl(session)).wait()
    } catch {
      error =>
        raise @posoco.SessionError::Save(
          "jsonl[js]: Bun.write rejected for " + path + ": " + error.to_string(),
        )
    }
    return
  }
  // File exists: append only the new message lines, each prefixed with \n to
  // terminate the previous line (same on-disk shape as the native writer).
  let buf = StringBuilder()
  for msg in messages {
    buf.write_char('\n')
    buf.write_string(message_to_json(msg).stringify())
  }
  try {
    let _ = fs_append_file(path, buf.to_string()).wait()
  } catch {
    error =>
      raise @posoco.SessionError::Save(
        "jsonl[js]: appendFile rejected for " + path + ": " + error.to_string(),
      )
  }
}
