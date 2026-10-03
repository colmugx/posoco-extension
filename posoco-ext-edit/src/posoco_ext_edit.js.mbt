// js (bun) target: file IO through node:fs sync APIs, all synchronous — no
// Promise bridging. node:fs members are bound with `#module` and injected
// into the inline-JS envelopes as values (pattern follows
// posoco-ext-workspace fs_port.js.mbt / moonbitlang/x/fs/fs_js.mbt).
// Throwing node calls cross the FFI as JSON string envelopes decoded on the
// MoonBit side because plain raising extern forms cannot represent these
// failures safely.

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
  #|   } catch (e) { return JSON.stringify({ ok: false, err: String(e && e.message ? e.message : e) }); }
  #| }

///|
extern "js" fn js_read_text_envelope(
  read_text : (String, String) -> String,
  path : String,
) -> String =
  #| (readText, path) => {
  #|   try { return JSON.stringify({ ok: true, text: readText(path, "utf8") }); }
  #|   catch (e) { return JSON.stringify({ ok: false, err: String(e && e.message ? e.message : e) }); }
  #| }

///|
extern "js" fn js_write_envelope(
  write_file : (String, String) -> Unit,
  path : String,
  data : String,
) -> String =
  #| (writeFile, path, data) => {
  #|   try { writeFile(path, data); return JSON.stringify({ ok: true }); }
  #|   catch (e) { return JSON.stringify({ ok: false, err: String(e && e.message ? e.message : e) }); }
  #| }

///|
extern "js" fn js_rename_envelope(
  rename : (String, String) -> Unit,
  old_path : String,
  new_path : String,
) -> String =
  #| (rename, oldPath, newPath) => {
  #|   try { rename(oldPath, newPath); return JSON.stringify({ ok: true }); }
  #|   catch (e) { return JSON.stringify({ ok: false, err: String(e && e.message ? e.message : e) }); }
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
/// `Err(cause)` carries the node error text from the envelope's `err` field;
/// envelope-shape anomalies report a literal cause instead.
fn js_stat_info(path : String) -> Result[JsStatInfo, String] {
  let json : Json = @json.parse(js_stat_envelope(fs_stat_sync, path)) catch {
    _ => return Err("malformed stat envelope")
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ => return Err("malformed stat envelope")
  }
  let ok = match fields.get("ok") {
    Some(Json::True) => true
    _ => false
  }
  if !ok {
    let cause = match fields.get("err") {
      Some(Json::String(value)) => value
      _ => "stat failed"
    }
    return Err(cause)
  }
  let size = match fields.get("size") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 0
  }
  let ms = match fields.get("ms") {
    Some(Json::Number(value, ..)) => value
    _ => 0.0
  }
  Ok({ ok: true, size, ms, })
}

///|
/// `None` on success; `Some(cause)` carries the failure text from the
/// envelope's `err` field.
fn js_envelope_err(envelope : String) -> String? {
  let json : Json = @json.parse(envelope) catch {
    _ => return Some("malformed envelope")
  }
  match json {
    Json::Object(fields) =>
      match fields.get("ok") {
        Some(Json::True) => None
        _ =>
          match fields.get("err") {
            Some(Json::String(value)) => Some(value)
            _ => Some("operation failed")
          }
      }
    _ => Some("malformed envelope")
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
  let info = match js_stat_info(path) {
    Ok(info) => info
    Err(cause) => raise edit_failure("stat", path, cause)
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
    _ => raise edit_failure("decode", path, "malformed read envelope")
  }
  let fields = match envelope {
    Json::Object(fields) => fields
    _ => raise edit_failure("decode", path, "malformed read envelope")
  }
  match (fields.get("ok"), fields.get("text")) {
    (Some(Json::True), Some(Json::String(text))) => text
    _ => {
      let cause = match fields.get("err") {
        Some(Json::String(value)) => value
        _ => "malformed read envelope"
      }
      raise edit_failure("read", path, cause)
    }
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
  match js_envelope_err(js_write_envelope(fs_write_file_sync, tmp, content)) {
    Some(cause) => raise edit_failure("write", path, cause)
    None => ()
  }
  match js_envelope_err(js_rename_envelope(fs_rename_sync, tmp, path)) {
    Some(cause) => raise edit_failure("write", path, cause)
    None => ()
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
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let call : @posoco.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }
  execute_edit_impl(JsFsIo::{ }, self.freshness, self.anchor, call)
}
