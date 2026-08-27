// js (bun) target: file IO through node:fs sync APIs, all synchronous — no
// Promise bridging. History: (1) BunFile `size`/`lastModified` are plain
// number getters, not Promises — declaring them `@js_async.Promise` and
// calling `.wait()` crashed with `p.then is not a function`; (2) `extern "js"
// fn ... raise` typechecks but its call sites decode a MoonBit Result
// (`$tag === 1`) that a raw node return value never has, so EVERY call
// fails. Both facts are recorded in docs/questions.md (2026-08-19). Throwing
// node calls therefore cross the FFI as JSON string envelopes decoded on the
// MoonBit side — the same boundary shape cetas-js's host_* functions use.

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
  #|     return JSON.stringify({ ok: true, size: st.size, ms: st.mtimeMs, dir: st.isDirectory() });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_read_text_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { return JSON.stringify({ ok: true, text: fs.readFileSync(path, "utf8") }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
/// Decoded stat envelope.
priv struct JsStatInfo {
  ok : Bool
  size : Int
  ms : Double
  is_dir : Bool
}

///|
fn js_stat_info(path : String) -> JsStatInfo {
  let json : Json = @json.parse(js_stat_envelope(path)) catch {
    _ => return { ok: false, size: 0, ms: 0.0, is_dir: false }
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ => return { ok: false, size: 0, ms: 0.0, is_dir: false }
  }
  let ok = match fields.get("ok") {
    Some(Json::True) => true
    _ => false
  }
  if !ok {
    return { ok: false, size: 0, ms: 0.0, is_dir: false }
  }
  let size = match fields.get("size") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 0
  }
  let ms = match fields.get("ms") {
    Some(Json::Number(value, ..)) => value
    _ => 0.0
  }
  let is_dir = match fields.get("dir") {
    Some(Json::True) => true
    _ => false
  }
  { ok: true, size, ms, is_dir }
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
/// Directory classification matches the native adaptor: a directory read
/// surfaces with the `read` stage, not `stat`.
impl FsIo for JsFsIo with fn stat(_self, path : String) -> @devkit.FileStamp {
  let info = js_stat_info(path)
  if !info.ok {
    raise read_failure("stat", path)
  }
  if info.is_dir {
    raise read_failure("read", path)
  }
  let mtime_s = (info.ms / 1000.0).to_int64()
  let mtime_ns = (info.ms % 1000.0 * 1_000_000.0).to_int()
  { mtime_s, mtime_ns, size: info.size.to_int64() }
}

///|
/// Split decoded text into normalized lines: split on `\n`, strip one
/// trailing `\r` per line, drop the phantom empty line produced by a final
/// newline. An empty file yields zero lines.
fn js_split_lines(text : String) -> Array[String] {
  let raw = text.split("\n").to_array()
  let has_final_newline = text.length() > 0 && text[text.length() - 1] == '\n'
  let effective = if has_final_newline && raw.length() > 0 {
    raw.length() - 1
  } else {
    raw.length()
  }
  let lines : Array[String] = []
  for i in 0..<effective {
    lines.push(strip_trailing_cr(raw[i].to_owned()))
  }
  lines
}

///|
/// One-shot read then slice. readFileSync(path, "utf8") reads + decodes
/// together, so a failure is IO or decode with no way to tell them apart
/// (stage `decode`, matching the previous behaviour).
fn js_read_page(
  path : String,
) -> (Array[String], Int64) raise @posoco.RuntimeError {
  let envelope : Json = @json.parse(js_read_text_envelope(path)) catch {
    _ => raise read_failure("decode", path)
  }
  let fields = match envelope {
    Json::Object(fields) => fields
    _ => raise read_failure("decode", path)
  }
  let text = match (fields.get("ok"), fields.get("text")) {
    (Some(Json::True), Some(Json::String(text))) => text
    _ => raise read_failure("decode", path)
  }
  let total_bytes = @utf8.encode(text).length()
  (js_split_lines(text), total_bytes.to_int64())
}

///|
impl FsIo for JsFsIo with fn read_lines(
  _self,
  path : String,
  skip : Int,
  take : Int,
) -> LinePage {
  let (lines, total_bytes) = js_read_page(path)
  let total = lines.length()
  let window : Array[String] = []
  for i in 0..<total {
    if i >= skip && window.length() < take {
      window.push(lines[i])
    }
  }
  { lines: window, total_lines: total, total_bytes }
}

///|
impl FsIo for JsFsIo with fn read_last_lines(_self, path : String, take : Int) -> LinePage {
  let (lines, total_bytes) = js_read_page(path)
  let total = lines.length()
  let take_eff = if take < total { take } else { total }
  let window = lines[total - take_eff:].to_owned()
  { lines: window, total_lines: total, total_bytes }
}

///|
pub impl @posoco.ToolProvider for ReadTools with fn list_tools(
  _self : ReadTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `read` tool on js. Business logic lives in the shared
/// `execute_read_impl`; this method only supplies the node:fs-backed adaptor.
pub impl @posoco.ToolProvider for ReadTools with fn execute(
  self : ReadTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_read_impl(JsFsIo::{  }, self.freshness, self.anchor, call)
}
