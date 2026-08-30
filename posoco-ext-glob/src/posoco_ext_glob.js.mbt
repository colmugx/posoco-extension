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
/// One stat envelope for both the directory check and the mtime sort.
extern "js" fn js_stat_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try {
  #|     const st = fs.statSync(path);
  #|     return JSON.stringify({ ok: true, dir: st.isDirectory(), mtimeMs: st.mtimeMs });
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
/// Decoded stat envelope.
priv struct JsStat {
  dir : Bool
  mtime_ms : Double
}

///|
/// Decode the stat envelope; None means the stat failed or the envelope is
/// malformed.
fn js_stat(path : String) -> JsStat? {
  let envelope : Json = @json.parse(js_stat_envelope(path)) catch {
    _ => return None
  }
  let fields = match envelope {
    Json::Object(fields) => fields
    _ => return None
  }
  match (fields.get("ok"), fields.get("dir")) {
    (Some(Json::True), dir) => {
      let mtime_ms = match fields.get("mtimeMs") {
        Some(Json::Number(value, ..)) => value
        _ => 0.0
      }
      match dir {
        Some(Json::True) => Some({ dir: true, mtime_ms, })
        _ => Some({ dir: false, mtime_ms, })
      }
    }
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
/// One recursion step: collect matching files under `dir` (whose path
/// relative to the scan base is `rel`), skipping dot entries and `ignores`
/// names the way the native scanner does — as results and as traversal
/// targets. Directories are never returned.
fn js_scan_dir(
  glob : BunGlob,
  ignores : Array[String],
  dir : String,
  rel : String,
  out : Array[(Double, String)],
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
    if @devkit.matches_ignore(entry_rel, ignores) {
      continue
    }
    let entry_full = js_path_join(dir, entry)
    match js_stat(entry_full) {
      Some(stat) =>
        if stat.dir {
          js_scan_dir(glob, ignores, entry_full, entry_rel, out)
        } else if glob.match_(entry_rel) {
          out.push((stat.mtime_ms, entry_rel))
        }
      // A failed stat means the entry vanished or is unreadable; skip it
      // rather than failing the whole scan.
      None => ()
    }
  }
}

///|
priv struct JsGlobScanner {
  ignores : Array[String]
}

///|
/// Walk the base directory and collect matching non-hidden files, newest
/// first (path ascending breaks mtime ties).
impl GlobScanner for JsGlobScanner with fn scan(
  self : JsGlobScanner,
  pattern : String,
  base : String,
) -> Array[String] {
  let glob = bun_glob_new(pattern)
  let normalized = if base == "" { "." } else { base }
  let found : Array[(Double, String)] = []
  js_scan_dir(glob, self.ignores, normalized, "", found)
  found.sort_by((a, b) => {
    let (a_ms, a_path) = a
    let (b_ms, b_path) = b
    if a_ms == b_ms {
      a_path.compare(b_path)
    } else if a_ms < b_ms {
      1
    } else {
      -1
    }
  })
  let out : Array[String] = []
  for entry in found {
    let (_, path) = entry
    out.push(path)
  }
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
  self : GlobTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_glob_impl(
    JsGlobScanner::{ ignores: self.ignores, },
    self.anchor,
    call,
  )
}
