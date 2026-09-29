// js (bun) target: file IO through node:fs sync APIs, all synchronous — no
// Promise bridging. node:fs members are bound with `#module` (the compiler
// emits the import) and injected into the inline-JS envelopes as values;
// pattern follows posoco-ext-workspace fs_port.js.mbt /
// moonbitlang/x/fs/fs_js.mbt. Throwing node calls cross the FFI as JSON
// string envelopes decoded on the MoonBit side.

///|
/// node:fs existsSync never throws; a plain pass-through extern is safe.
#module("node:fs")
extern "js" fn node_fs_exists_sync(path : String) -> Bool = "existsSync"

///|
/// Opaque node Stats / Buffer handles; only the inline-JS envelopes touch
/// them.
#external
priv type FsStats

///|
#external
priv type FsBuffer

///|
#module("node:fs")
extern "js" fn fs_stat_sync(path : String) -> FsStats = "statSync"

///|
/// The 2-arg readFileSync returns a JS string; the 1-arg form returns a
/// Buffer, whose base64 conversion stays inside the envelope.
#module("node:fs")
extern "js" fn fs_read_text_sync(path : String, encoding : String) -> String = "readFileSync"

///|
#module("node:fs")
extern "js" fn fs_read_buffer_sync(path : String) -> FsBuffer = "readFileSync"

///|
extern "js" fn js_stat_envelope(
  stat : (String) -> FsStats,
  path : String,
) -> String =
  #| (stat, path) => {
  #|   try {
  #|     const st = stat(path);
  #|     return JSON.stringify({ ok: true, size: st.size, ms: st.mtimeMs, dir: st.isDirectory() });
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
extern "js" fn js_read_base64_envelope(
  read_buffer : (String) -> FsBuffer,
  path : String,
) -> String =
  #| (readBuffer, path) => {
  #|   try {
  #|     return JSON.stringify({ ok: true, b64: readBuffer(path).toString("base64") });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
priv struct JsStatInfo {
  ok : Bool
  size : Int
  ms : Double
  is_dir : Bool
}

///|
fn js_stat_info(path : String) -> JsStatInfo {
  let json : Json = @json.parse(js_stat_envelope(fs_stat_sync, path)) catch {
    _ => return { ok: false, size: 0, ms: 0.0, is_dir: false, }
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ => return { ok: false, size: 0, ms: 0.0, is_dir: false, }
  }
  let ok = match fields.get("ok") {
    Some(Json::True) => true
    _ => false
  }
  if !ok {
    return { ok: false, size: 0, ms: 0.0, is_dir: false, }
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
  { ok: true, size, ms, is_dir, }
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
  { mtime_s, mtime_ns, size: info.size.to_int64(), }
}

///|
/// One-shot read then slice. readFileSync(path, "utf8") reads + decodes
/// together, so a failure is IO or decode with no way to tell them apart
/// (stage `decode`).
fn js_read_page(
  path : String,
) -> (Array[String], Int64) raise @posoco.RuntimeError {
  let envelope : Json = @json.parse(
    js_read_text_envelope(fs_read_text_sync, path),
  ) catch {
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
  (split_file_lines(text), total_bytes.to_int64())
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
  { lines: window, total_lines: total, total_bytes, }
}

///|
impl FsIo for JsFsIo with fn read_last_lines(_self, path : String, take : Int) -> LinePage {
  let (lines, total_bytes) = js_read_page(path)
  let total = lines.length()
  let take_eff = if take < total { take } else { total }
  let window = lines[total - take_eff:].to_owned()
  { lines: window, total_lines: total, total_bytes, }
}

///|
impl FsIo for JsFsIo with fn read_image_base64(_self, path : String) -> String {
  let json : Json = @json.parse(
    js_read_base64_envelope(fs_read_buffer_sync, path),
  ) catch {
    _ => raise read_failure("read", path)
  }
  guard json is Json::Object(fields) else { raise read_failure("read", path) }
  let ok = fields.get("ok") is Some(Json::True)
  let b64 = fields.get("b64")
  if ok && b64 is Some(Json::String(value)) {
    value
  } else {
    raise read_failure("read", path)
  }
}

///|
pub impl @posoco.ToolProvider for ReadTools with fn list_tools(
  _self : ReadTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `read` tool on js. Business logic lives in the shared
/// `execute_read_impl`; this method only supplies the IO adaptor: the
/// node:fs-backed one by default, or the injected-WorkspaceFs adaptor (with
/// node:fs kept for the freshness stat) when `fs` was provided.
pub impl @posoco.ToolProvider for ReadTools with fn execute(
  self : ReadTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let io : &FsIo = match self.fs {
    Some(fs) => DelegatedFsIo::{ fs, direct: JsFsIo::{ }, } as &FsIo
    None => JsFsIo::{ } as &FsIo
  }
  execute_read_impl(io, self.freshness, self.anchor, call)
}

///|
pub extend ReadTools with @posoco.ToolProvider::{list_tools}
