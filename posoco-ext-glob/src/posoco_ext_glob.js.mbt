// js (bun) target: scanning through node:fs sync APIs, pattern matching
// through Bun.Glob — the same engine the previous `glob.scan()` call used,
// applied per path instead of as an async iterator. All synchronous; no
// Promise bridging. Throwing node calls cross the FFI as JSON string
// envelopes (see posoco-ext-read's js adaptor and docs/questions.md
// 2026-08-19); Bun.Glob's `match` never throws for a valid pattern, so it
// stays a plain pass-through extern.

///|
extern "js" fn js_readdir_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { return JSON.stringify({ ok: true, entries: fs.readdirSync(path) }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_is_directory_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try {
  #|     const st = fs.statSync(path);
  #|     return JSON.stringify({ ok: true, dir: st.isDirectory() });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
/// Bun.Glob matcher (opaque).
#external
priv type BunGlob

///|
extern "js" fn bun_glob_new(pattern : String) -> BunGlob =
  #| (pattern) => new Bun.Glob(pattern)

///|
extern "js" fn BunGlob::match_(self : BunGlob, path : String) -> Bool =
  #| (glob, path) => glob.match(path)

///|
/// Decode the readdir envelope; None means the directory could not be read.
fn js_readdir_entries(path : String) -> Array[String]? {
  let envelope : Json = @json.parse(js_readdir_envelope(path)) catch {
    _ => return None
  }
  let fields = match envelope {
    Json::Object(fields) => fields
    _ => return None
  }
  match (fields.get("ok"), fields.get("entries")) {
    (Some(Json::True), Some(Json::Array(items))) => {
      let entries : Array[String] = []
      for item in items {
        match item {
          Json::String(entry) => entries.push(entry)
          _ => return None
        }
      }
      Some(entries)
    }
    _ => None
  }
}

///|
/// Decode the is-directory envelope; None means the stat failed or the
/// envelope is malformed.
fn js_is_directory(path : String) -> Bool? {
  let envelope : Json = @json.parse(js_is_directory_envelope(path)) catch {
    _ => return None
  }
  let fields = match envelope {
    Json::Object(fields) => fields
    _ => return None
  }
  match (fields.get("ok"), fields.get("dir")) {
    (Some(Json::True), Some(Json::True)) => Some(true)
    (Some(Json::True), _) => Some(false)
    _ => None
  }
}

///|
/// Join a directory path and an entry name with "/".
fn js_path_join(dir : String, entry : String) -> String {
  if dir == "" || dir == "." {
    entry
  } else if dir.has_suffix("/") {
    dir + entry
  } else {
    dir + "/" + entry
  }
}

///|
/// One recursion step: collect matches under `dir` (whose path relative to
/// the scan base is `rel`), skipping dot entries the way Bun.Glob's
/// `dot: false` default does — both as results and as traversal targets.
fn js_scan_dir(
  glob : BunGlob,
  dir : String,
  rel : String,
  out : Array[String],
) -> Unit raise @posoco.RuntimeError {
  let entries = match js_readdir_entries(dir) {
    Some(entries) => entries
    None =>
      raise @posoco.RuntimeError::InvocationFailed(
        "glob: scan failed for '\{@devkit.sanitize_path(dir)}'",
      )
  }
  for entry in entries {
    if entry.has_prefix(".") {
      continue
    }
    let entry_rel = js_path_join(rel, entry)
    if glob.match_(entry_rel) {
      out.push(entry_rel)
    }
    let entry_full = js_path_join(dir, entry)
    // A failed stat means the entry vanished or is unreadable; skip
    // recursion for it rather than failing the whole scan.
    match js_is_directory(entry_full) {
      Some(true) => js_scan_dir(glob, entry_full, entry_rel, out)
      _ => ()
    }
  }
}

///|
priv struct JsGlobScanner {}

///|
/// Walk the base directory and match every non-hidden path against the
/// pattern through Bun.Glob's matcher.
impl GlobScanner for JsGlobScanner with fn scan(
  _self,
  pattern : String,
  base : String,
) -> Array[String] {
  let glob = bun_glob_new(pattern)
  let normalized = if base == "" { "." } else { base }
  let out : Array[String] = []
  js_scan_dir(glob, normalized, "", out)
  out
}

///|
pub impl @posoco.ToolProvider for GlobTools with fn list_tools(
  _self : GlobTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `glob` tool on js. Business logic lives in the shared
/// `execute_glob_impl`; this method only supplies the walker + Bun.Glob
/// matcher.
pub impl @posoco.ToolProvider for GlobTools with fn execute(
  _self : GlobTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_glob_impl(JsGlobScanner::{  }, call)
}
