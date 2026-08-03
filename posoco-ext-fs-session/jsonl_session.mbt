///|
/// jsonl_session.mbt — Native target (Linux/macOS) implementation.

///|
/// Persistent JSONL-backed session store.
pub(all) struct JsonlSessionStore {
  root_dir : String
}

///|
pub fn JsonlSessionStore::new(root_dir : String) -> JsonlSessionStore {
  { root_dir, }
}

///|
fn xfs_error_detail(error : @xfs.IOError) -> String {
  match error {
    @xfs.IOError::IOError(detail) => detail
  }
}

///|
fn load_session_path(
  root_dir : String,
  id : String,
) -> String raise @posoco.SessionError {
  match validate_session_id(id) {
    Ok(_) => jsonl_session_path(root_dir, id)
    Err(reason) => raise @posoco.SessionError::Load("jsonl: " + reason)
  }
}

///|
fn save_session_path(
  root_dir : String,
  id : String,
) -> String raise @posoco.SessionError {
  match validate_session_id(id) {
    Ok(_) => jsonl_session_path(root_dir, id)
    Err(reason) => raise @posoco.SessionError::Save("jsonl: " + reason)
  }
}

///|
fn JsonlSessionStore::ensure_root_dir(
  self : JsonlSessionStore,
) -> Unit raise @posoco.SessionError {
  if @xfs.path_exists(self.root_dir) {
    let root_is_dir : Bool = @xfs.is_dir(self.root_dir) catch {
      e =>
        raise @posoco.SessionError::Save(
          "jsonl: failed to inspect session root " +
          self.root_dir +
          ": " +
          xfs_error_detail(e),
        )
    }
    if !root_is_dir {
      raise @posoco.SessionError::Save(
        "jsonl: session root is not a directory " + self.root_dir,
      )
    }
  } else {
    @xfs.create_dir(self.root_dir) catch {
      e =>
        raise @posoco.SessionError::Save(
          "jsonl: failed to create root " +
          self.root_dir +
          ": " +
          xfs_error_detail(e),
        )
    }
  }
}

///|
/// SessionStore::load — read JSONL, parse, return Session.
/// Missing file → empty session (not an error). Parse failure → SessionError::Load.
pub impl @posoco.SessionStore for JsonlSessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session raise @posoco.SessionError {
  let path = load_session_path(self.root_dir, id)
  let exists = @xfs.path_exists(path)
  if !exists {
    return @posoco.Session::{ messages: [], metadata: Map::from_array([]) }
  }
  let content = @xfs.read_file_to_string(path) catch {
    e =>
      raise @posoco.SessionError::Load(
        "jsonl: failed to read " + path + ": " + xfs_error_detail(e),
      )
  }
  match session_from_jsonl(content) {
    Ok(s) => s
    Err(e) => raise e
  }
}

///|
/// SessionStore::save — serialise session and replace the file contents.
/// Directory is created lazily.
pub impl @posoco.SessionStore for JsonlSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  let path = save_session_path(self.root_dir, id)
  self.ensure_root_dir()
  let jsonl = session_to_jsonl(session)
  @xfs.write_string_to_file(path, jsonl) catch {
    e =>
      raise @posoco.SessionError::Save(
        "jsonl: failed to write " + path + ": " + xfs_error_detail(e),
      )
  }
}
