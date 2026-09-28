///|
/// jsonl_session.js.mbt — JS target implementation.
///
/// node:fs sync APIs bound with `#module` and injected into the inline-JS
/// wrappers as values (pattern follows posoco-ext-workspace fs_port.js.mbt /
/// moonbitlang/x/fs/fs_js.mbt). Unlike Bun.write, writeFileSync does not
/// create parent directories, so every write ensures the store root first.

///|
/// Persistent JSONL-backed session store (bun runtime).
pub(all) struct JsonlSessionStore {
  root_dir : String
  bus : @devkit.EventBus?
  /// Id of the session this store last persisted successfully; the /name
  /// command targets it, so slash consumers need no explicit session id.
  mut current_id : String?
}

///|
pub fn JsonlSessionStore::JsonlSessionStore(
  root_dir : String,
  bus? : @devkit.EventBus? = None,
) -> JsonlSessionStore {
  { root_dir, bus, current_id: None, }
}

///|
/// node:fs bindings. mkdirSync's 2nd argument is a JS options object, so the
/// declared 2nd parameter is only a value-passing shape; the wrapper builds
/// `{ recursive: true }` on the JS side.
#module("node:fs")
extern "js" fn fs_exists_sync(path : String) -> Bool = "existsSync"

///|
#module("node:fs")
extern "js" fn fs_read_text_sync(path : String, encoding : String) -> String = "readFileSync"

///|
#module("node:fs")
extern "js" fn fs_write_file_sync(path : String, data : String) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn fs_mkdir_sync(path : String, recursive : Bool) -> Unit = "mkdirSync"

///|
#module("node:fs")
extern "js" fn fs_append_file_sync(path : String, data : String) -> Unit = "appendFileSync"

///|
/// Opaque ok/content results: "" cannot double as a failure sentinel
/// (empty session files are valid content).
#external
priv type JsTextResult

///|
#external
priv type JsWriteResult

///|
extern "js" fn JsTextResult::is_ok(self : Self) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn JsTextResult::content(self : Self) -> String =
  #| (res) => res.content

///|
extern "js" fn JsWriteResult::is_ok(self : Self) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn JsWriteResult::content(self : Self) -> String =
  #| (res) => res.content

///|
extern "js" fn js_read_text_ffi(
  read_text : (String, String) -> String,
  path : String,
) -> JsTextResult =
  #| (readFile, path) => {
  #|   try {
  #|     return { ok: true, content: readFile(path, "utf8") };
  #|   } catch (error) {
  #|     return { ok: false, content: String(error?.message ?? error) };
  #|   }
  #| }

///|
extern "js" fn js_write_file_ffi(
  mkdir : (String, Bool) -> Unit,
  write_file : (String, String) -> Unit,
  root_dir : String,
  path : String,
  data : String,
) -> JsWriteResult =
  #| (mkdir, writeFile, rootDir, path, data) => {
  #|   try { mkdir(rootDir, { recursive: true }); } catch (e) {}
  #|   try { writeFile(path, data); return { ok: true, content: "" }; }
  #|   catch (error) { return { ok: false, content: String(error?.message ?? error) }; }
  #| }

///|
extern "js" fn js_append_file_ffi(
  append_file : (String, String) -> Unit,
  path : String,
  data : String,
) -> JsWriteResult =
  #| (appendFile, path, data) => {
  #|   try { appendFile(path, data); return { ok: true, content: "" }; }
  #|   catch (error) { return { ok: false, content: String(error?.message ?? error) }; }
  #| }

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
  if !fs_exists_sync(path) {
    return @posoco.Session::{ messages: [], metadata: Map::from_array([]), }
  }
  let res = js_read_text_ffi(fs_read_text_sync, path)
  if !res.is_ok() {
    raise @posoco.SessionError::Load(
      "jsonl[js]: readFileSync failed for " + path + ": " + res.content(),
    )
  }
  match session_from_jsonl(res.content()) {
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
  let res = js_write_file_ffi(
    fs_mkdir_sync,
    fs_write_file_sync,
    self.root_dir,
    path,
    jsonl,
  )
  if !res.is_ok() {
    raise @posoco.SessionError::Save(
      "jsonl[js]: write failed for " + path + ": " + res.content(),
    )
  }
  publish_session_status(self.bus, id)
  self.current_id = Some(id)
}

///|
/// A missing file gets a full JSONL write (metadata + messages) so the first
/// append behaves like a save; an existing file only receives the new message
/// lines.
pub impl @posoco.SessionStore for JsonlSessionStore with fn append_messages(
  self,
  id : String,
  from_index : Int,
  messages : ArrayView[@posoco.Message],
) -> Unit raise @posoco.SessionError {
  let _ = from_index
  let path = js_save_session_path(self.root_dir, id)
  if !fs_exists_sync(path) {
    let session : @posoco.Session = {
      messages: messages.to_owned(),
      metadata: Map::from_array([]),
    }
    let res = js_write_file_ffi(
      fs_mkdir_sync,
      fs_write_file_sync,
      self.root_dir,
      path,
      session_to_jsonl(session),
    )
    if !res.is_ok() {
      raise @posoco.SessionError::Save(
        "jsonl[js]: write failed for " + path + ": " + res.content(),
      )
    }
    publish_session_status(self.bus, id)
    self.current_id = Some(id)
    return
  }
  // Each line is prefixed with \n to terminate the previous line.
  let buf = StringBuilder()
  for msg in messages {
    buf.write_char('\n')
    buf.write_string(message_to_json(msg).stringify())
  }
  let res = js_append_file_ffi(fs_append_file_sync, path, buf.to_string())
  if !res.is_ok() {
    raise @posoco.SessionError::Save(
      "jsonl[js]: appendFile failed for " + path + ": " + res.content(),
    )
  }
  publish_session_status(self.bus, id)
  self.current_id = Some(id)
}

///|
pub extend JsonlSessionStore with @posoco.SessionStore::{
  checkpoint,
  save,
  append_messages,
  load,
  truncate,
}
