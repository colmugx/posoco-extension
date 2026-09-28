// js (bun) target: file IO through node:fs sync APIs, all synchronous — no
// Promise bridging. node:fs members are bound with `#module` and injected
// into the inline-JS envelopes as values (pattern follows
// posoco-ext-workspace fs_port.js.mbt / moonbitlang/x/fs/fs_js.mbt).
// Throwing node calls cross the FFI as JSON string envelopes decoded on the
// MoonBit side (see docs/questions.md 2026-08-19 for why plain/raising
// extern forms are not usable for them; the `require` fallback recorded
// there is retired).

///|
/// node:fs existsSync never throws; a plain pass-through extern is safe.
#module("node:fs")
extern "js" fn node_fs_exists_sync(path : String) -> Bool = "existsSync"

///|
#external
priv type FsStats

///|
#module("node:fs")
extern "js" fn fs_stat_sync(path : String) -> FsStats = "statSync"

///|
#module("node:fs")
extern "js" fn fs_read_text_sync(path : String, encoding : String) -> String = "readFileSync"

///|
#module("node:fs")
extern "js" fn fs_write_file_sync(path : String, data : String) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn fs_rename_sync(old_path : String, new_path : String) -> Unit = "renameSync"

///|
extern "js" fn js_stat_envelope(
  stat : (String) -> FsStats,
  path : String,
) -> String =
  #| (stat, path) => {
  #|   try {
  #|     const st = stat(path);
  #|     return JSON.stringify({ ok: true, size: st.size, ms: st.mtimeMs });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_read_text_envelope(
  read_text : (String, String) -> String,
  path : String,
) -> String =
  #| (readText, path) => {
  #|   try { return JSON.stringify({ ok: true, text: readText(path, "utf8") }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_write_envelope(
  write_file : (String, String) -> Unit,
  path : String,
  data : String,
) -> String =
  #| (writeFile, path, data) => {
  #|   try { writeFile(path, data); return JSON.stringify({ ok: true }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_rename_envelope(
  rename : (String, String) -> Unit,
  old_path : String,
  new_path : String,
) -> String =
  #| (rename, oldPath, newPath) => {
  #|   try { rename(oldPath, newPath); return JSON.stringify({ ok: true }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
/// `Date.now()` — unique-enough temp suffix component.
extern "js" fn js_now_ms() -> Int =
  #| () => Date.now()

///|
/// Decoded stat envelope (write/edit never need the directory flag).
priv struct JsStatInfo {
  ok : Bool
  size : Int
  ms : Double
}

///|
fn js_stat_info(path : String) -> JsStatInfo {
  let json : Json = @json.parse(js_stat_envelope(fs_stat_sync, path)) catch {
    _ => return { ok: false, size: 0, ms: 0.0, }
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ => return { ok: false, size: 0, ms: 0.0, }
  }
  let ok = match fields.get("ok") {
    Some(Json::True) => true
    _ => false
  }
  if !ok {
    return { ok: false, size: 0, ms: 0.0, }
  }
  let size = match fields.get("size") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 0
  }
  let ms = match fields.get("ms") {
    Some(Json::Number(value, ..)) => value
    _ => 0.0
  }
  { ok: true, size, ms, }
}

///|
fn js_envelope_ok(envelope : String) -> Bool {
  let json : Json = @json.parse(envelope) catch { _ => return false }
  match json {
    Json::Object(fields) =>
      match fields.get("ok") {
        Some(Json::True) => true
        _ => false
      }
    _ => false
  }
}

///|
priv struct JsFsIo {}

///|
/// existsSync returns false for a missing file and never throws.
impl FsIo for JsFsIo with fn exists(_self, path : String) -> Bool {
  node_fs_exists_sync(path)
}

///|
/// Stamp from statSync: `mtimeMs` plus `size` (ms granularity; the
/// guard only compares stamps from the same runtime).
impl FsIo for JsFsIo with fn stat(_self, path : String) -> @devkit.FileStamp {
  let info = js_stat_info(path)
  if !info.ok {
    raise edit_failure("stat", path)
  }
  let mtime_s = (info.ms / 1000.0).to_int64()
  let mtime_ns = (info.ms % 1000.0 * 1_000_000.0).to_int()
  { mtime_s, mtime_ns, size: info.size.to_int64(), }
}

///|
impl FsIo for JsFsIo with fn read_text(_self, path : String) -> String {
  let envelope : Json = @json.parse(
    js_read_text_envelope(fs_read_text_sync, path),
  ) catch {
    _ => raise edit_failure("decode", path)
  }
  let fields = match envelope {
    Json::Object(fields) => fields
    _ => raise edit_failure("decode", path)
  }
  match (fields.get("ok"), fields.get("text")) {
    (Some(Json::True), Some(Json::String(text))) => text
    _ => raise edit_failure("decode", path)
  }
}

///|
/// Atomic write: sibling temp file, then `renameSync` (rename(2)) over target.
impl FsIo for JsFsIo with fn write_atomic(
  _self,
  path : String,
  content : String,
) -> Unit {
  let tmp = "\{path}.tmp-\{js_now_ms()}"
  if !js_envelope_ok(js_write_envelope(fs_write_file_sync, tmp, content)) {
    raise edit_failure("write", path)
  }
  if !js_envelope_ok(js_rename_envelope(fs_rename_sync, tmp, path)) {
    raise edit_failure("write", path)
  }
}

///|
pub impl @posoco.ToolProvider for EditTools with fn list_tools(
  _self : EditTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `edit` tool on js. Business logic lives in the shared
/// `execute_edit_impl`; this method only supplies the node:fs-backed adaptor.
pub impl @posoco.ToolProvider for EditTools with fn execute(
  self : EditTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_edit_impl(JsFsIo::{ }, self.freshness, self.anchor, call)
}
