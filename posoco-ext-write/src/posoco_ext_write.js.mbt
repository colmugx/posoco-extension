// js (bun) target: file IO through node:fs sync APIs, all synchronous — no
// Promise bridging. Throwing node calls cross the FFI as JSON string
// envelopes decoded on the MoonBit side (see posoco-ext-read's js adaptor
// and docs/questions.md 2026-08-19 for why plain/raising extern forms are
// not usable for them).

///|
/// node:fs existsSync never throws; a plain pass-through extern is safe.
#module("node:fs")
extern "js" fn node_fs_exists_sync(path : String) -> Bool = "existsSync"

///|
extern "js" fn js_stat_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try {
  #|     const st = fs.statSync(path);
  #|     return JSON.stringify({ ok: true, size: st.size, ms: st.mtimeMs });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
/// `{ok}` envelope for throwing mutations; the MoonBit side only needs
/// success/failure — failures surface as the tool's typed stage error.
extern "js" fn js_write_envelope(path : String, data : String) -> String =
  #| (path, data) => {
  #|   const fs = require("node:fs");
  #|   try { fs.writeFileSync(path, data); return JSON.stringify({ ok: true }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_rename_envelope(
  old_path : String,
  new_path : String,
) -> String =
  #| (oldPath, newPath) => {
  #|   const fs = require("node:fs");
  #|   try { fs.renameSync(oldPath, newPath); return JSON.stringify({ ok: true }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_mkdir_recursive_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { fs.mkdirSync(path, { recursive: true }); return JSON.stringify({ ok: true }); }
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
  let json : Json = @json.parse(js_stat_envelope(path)) catch {
    _ => return { ok: false, size: 0, ms: 0.0 }
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ => return { ok: false, size: 0, ms: 0.0 }
  }
  let ok = match fields.get("ok") {
    Some(Json::True) => true
    _ => false
  }
  if !ok {
    return { ok: false, size: 0, ms: 0.0 }
  }
  let size = match fields.get("size") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 0
  }
  let ms = match fields.get("ms") {
    Some(Json::Number(value, ..)) => value
    _ => 0.0
  }
  { ok: true, size, ms }
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
/// Stamp from statSync: `mtimeMs` plus `size`. Millisecond mtime
/// granularity is what the js runtime offers; the guard only ever compares
/// stamps produced by the same runtime, so it stays self-consistent.
impl FsIo for JsFsIo with fn stat(_self, path : String) -> @devkit.FileStamp {
  let info = js_stat_info(path)
  if !info.ok {
    raise write_failure("stat", path)
  }
  let mtime_s = (info.ms / 1000.0).to_int64()
  let mtime_ns = (info.ms % 1000.0 * 1_000_000.0).to_int()
  { mtime_s, mtime_ns, size: info.size.to_int64() }
}

///|
/// Atomic write: ensure the parent dir, write a sibling temp file, then
/// `renameSync` (rename(2) under the hood) over the target.
impl FsIo for JsFsIo with fn write_atomic(
  _self,
  path : String,
  content : String,
) -> Unit {
  let parent = parent_dir(path)
  if parent != "." && parent != "/" {
    // A real failure here surfaces at write/rename below.
    let _ = js_mkdir_recursive_envelope(parent)
  }
  let tmp = "\{path}.tmp-\{js_now_ms()}"
  if !js_envelope_ok(js_write_envelope(tmp, content)) {
    raise write_failure("write", path)
  }
  if !js_envelope_ok(js_rename_envelope(tmp, path)) {
    raise write_failure("write", path)
  }
}

///|
pub impl @posoco.ToolProvider for WriteTools with fn list_tools(
  _self : WriteTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `write` tool on js. Business logic lives in the shared
/// `execute_write_impl`; this method only supplies the node:fs-backed adaptor.
pub impl @posoco.ToolProvider for WriteTools with fn execute(
  self : WriteTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_write_impl(JsFsIo::{  }, self.freshness, self.anchor, call)
}
