// js target: node:fs sync scanning with JSON-string envelopes; matching uses the
// shared `@devkit.glob_match` engine, so js and native semantics cannot drift.

///|
#external
priv type FsStats

///|
#module("node:fs")
extern "js" fn fs_readdir_sync(path : String) -> FixedArray[String] = "readdirSync"

///|
#module("node:fs")
extern "js" fn fs_stat_sync(path : String) -> FsStats = "statSync"

///|
extern "js" fn js_readdir_envelope(
  readdir : (String) -> FixedArray[String],
  path : String,
) -> String =
  #| (readdir, path) => {
  #|   try { return JSON.stringify({ ok: true, entries: readdir(path) }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
/// One stat envelope for both the directory check and the mtime sort.
extern "js" fn js_stat_envelope(
  stat : (String) -> FsStats,
  path : String,
) -> String =
  #| (stat, path) => {
  #|   try {
  #|     const st = stat(path);
  #|     return JSON.stringify({ ok: true, dir: st.isDirectory(), mtimeMs: st.mtimeMs });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
fn js_readdir_entries(path : String) -> Array[String]? {
  let envelope : Json = @json.parse(js_readdir_envelope(fs_readdir_sync, path)) catch {
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
priv struct JsStat {
  dir : Bool
  mtime_ms : Double
}

///|
fn js_stat(path : String) -> JsStat? {
  let envelope : Json = @json.parse(js_stat_envelope(fs_stat_sync, path)) catch {
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
  pattern : String,
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
          js_scan_dir(pattern, ignores, entry_full, entry_rel, out)
        } else if @devkit.glob_match(pattern, entry_rel) {
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
  let normalized = if base == "" { "." } else { base }
  let found : Array[(Double, String)] = []
  js_scan_dir(pattern, self.ignores, normalized, "", found)
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
/// Execute the `glob` tool on js; business logic lives in the shared
/// `execute_glob_impl`, this method only supplies the walker + matcher.
pub impl @posoco.ToolProvider for GlobTools with fn execute(
  self : GlobTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let call : @posoco.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }
  execute_glob_impl(
    JsGlobScanner::{ ignores: self.ignores, },
    self.anchor,
    call,
  )
}

///|
pub extend GlobTools with @posoco.ToolProvider::{list_tools}
