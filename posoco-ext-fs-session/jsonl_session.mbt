///|
/// jsonl_session.mbt — Native target (Linux/macOS) implementation.

///|
/// Persistent JSONL-backed session store.
pub(all) struct JsonlSessionStore {
  root_dir : String
  bus : @devkit.EventBus?
}

///|
pub fn JsonlSessionStore::JsonlSessionStore(
  root_dir : String,
  bus? : @devkit.EventBus? = None,
) -> JsonlSessionStore {
  { root_dir, bus, }
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
/// root_dir may be a nested path (e.g. `<home>/.cetas/sessions/--proj--`);
/// @xfs.create_dir is single-level on native, so missing parents are created
/// with the recursive mkdir from moonbitlang/async/fs.
async fn JsonlSessionStore::ensure_root_dir(
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
    @fs.mkdir(self.root_dir, recursive=true) catch {
      e =>
        raise @posoco.SessionError::Save(
          "jsonl: failed to create root " + self.root_dir + ": " + e.to_string(),
        )
    }
  }
}

///|
/// Directory entries of root_dir (native): an empty list when the root does
/// not exist; a non-directory root is a load-side defect.
async fn JsonlSessionStore::raw_dir_entries(
  self : JsonlSessionStore,
) -> Array[String] raise @posoco.SessionError {
  if !@xfs.path_exists(self.root_dir) {
    return []
  }
  let root_is_dir : Bool = @xfs.is_dir(self.root_dir) catch {
    e =>
      raise @posoco.SessionError::Load(
        "jsonl: failed to inspect session root " +
        self.root_dir +
        ": " +
        xfs_error_detail(e),
      )
  }
  if !root_is_dir {
    raise @posoco.SessionError::Load(
      "jsonl: session root is not a directory " + self.root_dir,
    )
  }
  @fs.readdir(self.root_dir, include_hidden=false) catch {
    e =>
      raise @posoco.SessionError::Load(
        "jsonl: failed to list " + self.root_dir + ": " + e.to_string(),
      )
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
    return @posoco.Session::{ messages: [], metadata: Map::from_array([]), }
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
  publish_session_status(self.bus, id)
}

///|
/// SessionStore::append_messages — append just the new JSONL message lines to
/// the file. If the session file does not exist yet, write a full JSONL file
/// (metadata + messages) so the first append behaves like a save.
pub impl @posoco.SessionStore for JsonlSessionStore with fn append_messages(
  self,
  id : String,
  from_index : Int,
  messages : ArrayView[@posoco.Message],
) -> Unit raise @posoco.SessionError {
  let _ = from_index
  let path = save_session_path(self.root_dir, id)
  self.ensure_root_dir()
  let exists = @xfs.path_exists(path)
  if !exists {
    // First persistence for this id: write metadata + all messages.
    let session : @posoco.Session = {
      messages: messages.to_owned(),
      metadata: Map::from_array([]),
    }
    let jsonl = session_to_jsonl(session)
    @xfs.write_string_to_file(path, jsonl) catch {
      e =>
        raise @posoco.SessionError::Save(
          "jsonl: failed to write " + path + ": " + xfs_error_detail(e),
        )
    }
    publish_session_status(self.bus, id)
    return
  }
  // File exists: open in append mode and write each new message line.
  let file = @fs.open(
    path,
    mode=@fs.Mode::WriteOnly,
    append=true,
    create_mode=@fs.CreateMode::OpenExisting,
  ) catch {
    e =>
      raise @posoco.SessionError::Save(
        "jsonl: failed to open " + path + " for append: " + e.to_string(),
      )
  }
  let writer = file as &@io.Writer
  for msg in messages {
    let line = "\n" + message_to_json(msg).stringify()
    writer.write(line) catch {
      e => {
        file.close()
        raise @posoco.SessionError::Save(
          "jsonl: failed to append to " + path + ": " + e.to_string(),
        )
      }
    }
  }
  file.close()
  publish_session_status(self.bus, id)
}
