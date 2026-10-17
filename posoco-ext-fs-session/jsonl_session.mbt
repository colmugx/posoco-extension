///|
/// jsonl_session.mbt — Native target (Linux/macOS) implementation.

///|
/// Persistent JSONL-backed session store.
pub(all) struct JsonlSessionStore {
  root_dir : String
  bus : @devkit.EventBus?
  /// Id of the session this store last persisted successfully; the /name
  /// command targets it, so slash consumers need no explicit session id.
  mut current_id : String?
  /// Latest ext-llm selection observed on the bus; `None` = no observation,
  /// in which case persisted metadata is never decorated.
  mut observed_selection : (String, String?)?
  /// Selection already reflected in the persisted metadata line, so the
  /// append fast path only rewrites line 1 after an observed change.
  mut written_selection : (String, String?)?
  mut observed_selection_v2 : SessionSelectionV2?
  mut written_selection_v2 : SessionSelectionV2?
  mut written_session_id : String?
  /// The active manager is read through its neutral control contract.
  selection_control : &@modelmgmt.ModelManagerControl?
  mut selection_revision : Int64
}

///|
pub fn JsonlSessionStore::JsonlSessionStore(
  root_dir : String,
  bus~ : @devkit.EventBus? = None,
  selection_control~ : &@modelmgmt.ModelManagerControl? = None,
) -> JsonlSessionStore {
  let store : JsonlSessionStore = {
    root_dir,
    bus,
    current_id: None,
    observed_selection: None,
    written_selection: None,
    observed_selection_v2: None,
    written_selection_v2: None,
    written_session_id: None,
    selection_control,
    selection_revision: 0L,
  }
  store.subscribe_model_selection(bus)
  store
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
pub extend JsonlSessionStore with @posoco.SessionStore::{
  save,
  append_messages,
  load,
  truncate,
  checkpoint,
}

///|
/// SessionStore::save — serialise session and replace the file contents.
/// Directory is created lazily. The persisted metadata line is decorated
/// with the latest observed model selection so the file remembers the
/// model/effort behind its transcript tail.
pub impl @posoco.SessionStore for JsonlSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  self.capture_selection()
  let path = save_session_path(self.root_dir, id)
  self.ensure_root_dir()
  let jsonl = session_to_jsonl({
    ..session,
    metadata: metadata_with_observed_selection_v2(
      metadata_with_selection(session.metadata, self.observed_selection),
      self.observed_selection_v2,
    ),
  })
  @xfs.write_string_to_file(path, jsonl) catch {
    e =>
      raise @posoco.SessionError::Save(
        "jsonl: failed to write " + path + ": " + xfs_error_detail(e),
      )
  }
  publish_session_status(self.bus, id)
  self.current_id = Some(id)
  self.mark_selection_written(self.observed_selection)
  self.written_session_id = Some(id)
}

///|
/// SessionStore::append_messages — append just the new JSONL message lines to
/// the file. If the session file does not exist yet, write a full JSONL file
/// (metadata + messages) so the first append behaves like a save.
pub impl @posoco.SessionStore for JsonlSessionStore with fn append_messages(
  self,
  id : String,
  from_index : Int32,
  messages : ArrayView[@posoco.Message],
) -> Unit raise @posoco.SessionError {
  let _ = from_index
  self.capture_selection()
  let path = save_session_path(self.root_dir, id)
  self.ensure_root_dir()
  let exists = @xfs.path_exists(path)
  if !exists {
    let session : @posoco.Session = {
      messages: messages.to_owned(),
      metadata: metadata_with_observed_selection_v2(
        metadata_with_selection(Map::from_array([]), self.observed_selection),
        self.observed_selection_v2,
      ),
    }
    let jsonl = session_to_jsonl(session)
    @xfs.write_string_to_file(path, jsonl) catch {
      e =>
        raise @posoco.SessionError::Save(
          "jsonl: failed to write " + path + ": " + xfs_error_detail(e),
        )
    }
    publish_session_status(self.bus, id)
    self.current_id = Some(id)
    self.mark_selection_written(self.observed_selection)
    self.written_session_id = Some(id)
    return
  }
  // A selection change since the last persist is recorded by rewriting only
  // the metadata line; unchanged selections keep the pure-append fast path.
  let mut metadata_written = true
  if self.written_session_id != Some(id) ||
    self.observed_selection != self.written_selection ||
    self.observed_selection_v2 != self.written_selection_v2 {
    metadata_written = self.refresh_metadata_selection(path)
  }
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
  self.current_id = Some(id)
  if metadata_written {
    self.mark_selection_written(self.observed_selection)
    self.written_session_id = Some(id)
  } else {
    self.written_session_id = None
  }
}

///|
/// Best-effort metadata-line rewrite for the append fast path: records a
/// freshly observed selection without disturbing appended history. I/O
/// failures are swallowed — the next full save heals the file, and the
/// caller marks the selection written only after the append itself succeeds.
fn JsonlSessionStore::refresh_metadata_selection(
  self : JsonlSessionStore,
  path : String,
) -> Bool noraise {
  let content = @xfs.read_file_to_string(path) catch { _ => return false }
  let updated_legacy = rewrite_metadata_line(
    content, self.observed_selection,
  ).unwrap_or(content)
  let updated = rewrite_metadata_line_v2(
    updated_legacy, self.observed_selection_v2,
  ).unwrap_or(updated_legacy)
  if updated != content {
    @xfs.write_string_to_file(path, updated) catch { _ => return false }
  }
  true
}
