// js target: engine ladder — banner-validated ripgrep when found (a shim only
// costs one wasted spawn), else the in-process node:fs walker; rg flags are
// pinned for parity with the walker (--no-ignore, --glob excludes, hidden
// skip, -F literals unless regex mode).

///|
#module("node:fs")
extern "js" fn fs_exists_sync(path : String) -> Bool = "existsSync"

///|
/// Absolute path of `name` on PATH, or "" when not found. node has no
/// built-in which; walk PATH (plus PATHEXT on Windows — the filesystem is
/// case-insensitive there, so ".EXE" candidates match ".exe" files).
extern "js" fn node_which(exists : (String) -> Bool, name : String) -> String =
  #| (exists, name) => {
  #|   if (name.includes("/") || name.includes("\\")) {
  #|     try { return exists(name) ? name : "" } catch { return "" }
  #|   }
  #|   const isWin = process.platform === "win32"
  #|   const dirs = (process.env.PATH ?? "").split(isWin ? ";" : ":").filter(Boolean)
  #|   const exts = isWin
  #|     ? (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";")
  #|     : []
  #|   const candidates = [name, ...exts.map((ext) => name + ext)]
  #|   for (const dir of dirs) {
  #|     const base = dir.endsWith("/") || dir.endsWith("\\") ? dir : dir + (isWin ? "\\" : "/")
  #|     for (const candidate of candidates) {
  #|       try { if (exists(base + candidate)) return base + candidate } catch {}
  #|     }
  #|   }
  #|   return ""
  #| }

///|
#external
priv type NodeSpawnOptions

///|
#external
priv type NodeProc

///|
#module("node:child_process")
extern "js" fn cp_spawn(
  file : String,
  args : FixedArray[String],
  options : NodeSpawnOptions,
) -> NodeProc = "spawn"

///|
extern "js" fn js_spawn_envelope(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> NodeProc,
  cmd : FixedArray[String],
) -> @js_async.Promise[String] =
  #| async (spawn, cmd) => {
  #|   const proc = spawn(cmd[0], cmd.slice(1), { stdio: ["ignore", "pipe", "pipe"] })
  #|   const drain = (stream) => stream
  #|     ? new Promise((resolve) => {
  #|         let text = ""
  #|         const finish = () => resolve(text)
  #|         stream.setEncoding("utf8")
  #|         stream.on("data", (chunk) => { text += chunk })
  #|         stream.on("end", finish)
  #|         stream.on("close", finish)
  #|         stream.on("error", finish)
  #|       })
  #|     : Promise.resolve("")
  #|   const [exitCode, stdout, stderr] = await Promise.all([
  #|     new Promise((resolve) => {
  #|       proc.on("close", (code) => resolve(code ?? -1))
  #|       proc.on("error", () => resolve(-1))
  #|     }),
  #|     drain(proc.stdout),
  #|     drain(proc.stderr),
  #|   ])
  #|   return JSON.stringify({ ok: true, exitCode, stdout, stderr })
  #| }

///|
priv struct JsSpawnResult {
  exit_code : Int32
  stdout : String
  stderr : String
}

///|
async fn js_spawn_result(cmd : Array[String]) -> JsSpawnResult noraise {
  let json : Json = @json.parse(
    js_spawn_envelope(cp_spawn, FixedArray::from_array(cmd)).wait(),
  ) catch {
    _ =>
      return {
        exit_code: 2,
        stdout: "",
        stderr: "spawn envelope decode failed",
      }
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ =>
      return {
        exit_code: 2,
        stdout: "",
        stderr: "spawn envelope is not an object",
      }
  }
  let exit_code = match fields.get("exitCode") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 2
  }
  let stdout = match fields.get("stdout") {
    Some(Json::String(text)) => text
    _ => ""
  }
  let stderr = match fields.get("stderr") {
    Some(Json::String(text)) => text
    _ => ""
  }
  { exit_code, stdout, stderr, }
}

///|
fn rg_candidates() -> Array[String] {
  let candidates : Array[String] = []
  let on_path = node_which(fs_exists_sync, "rg")
  if on_path != "" {
    candidates.push(on_path)
  }
  for fixed in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"] {
    if !candidates.contains(fixed) {
      candidates.push(fixed)
    }
  }
  candidates
}

///|
/// First candidate that is a real ripgrep (banner check rejects grep shims
/// and other look-alikes). None means the ladder falls through to the
/// in-process walker.
async fn probe_rg() -> String? noraise {
  for candidate in rg_candidates() {
    let result = js_spawn_result([candidate, "--version"])
    if result.exit_code == 0 && result.stdout.contains("ripgrep") {
      return Some(candidate)
    }
  }
  None
}

///|
/// rg argv for one search. Flags mirror the native walker's semantics:
/// NUL-separated output (safe against `:` in filenames), literal pattern
/// via -e (safe against leading `-`), fixed strings unless regex mode,
/// hidden skip is the rg default, and the ignore list rides in as negated
/// globs.
fn build_rg_args(
  bin : String,
  pattern : String,
  base : String,
  file_glob : String,
  case_insensitive : Bool,
  use_regex : Bool,
  ignores : Array[String],
) -> Array[String] {
  let args : Array[String] = [
    bin, "--line-number", "--color=never", "--no-heading", "--no-ignore", "--null",
  ]
  if !use_regex {
    args.push("-F")
  }
  if case_insensitive {
    args.push("-i")
  }
  for ignore in ignores {
    args.push("--glob")
    args.push("!\{ignore}")
  }
  if file_glob != "" {
    args.push("--glob")
    args.push(file_glob)
  }
  args.push("-e")
  args.push(pattern)
  args.push(base)
  args
}

///|
/// Parse one rg NUL-separated content-mode output line. Lines without a
/// numeric line prefix (binary-file summaries) yield None.
fn parse_rg_line(line : String) -> GrepMatch? {
  let idx = match line.find("\u{0}") {
    Some(idx) => idx
    None => return None
  }
  let path = line[:idx].to_owned()
  let rest = line[idx + 1:].to_owned()
  let sep = match rest.find(":") {
    Some(sep) => sep
    None => return None
  }
  let n = @string.parse_int(rest[:sep].to_owned()) catch { _ => return None }
  Some(GrepMatch::{ path, line: n, content: rest[sep + 1:].to_owned(), })
}

///|
/// Parse rg's NUL-separated content-mode output into matches. The `./`
/// prefix rg adds to relative results is stripped later by the shared impl.
fn parse_rg_stdout(stdout : String) -> Array[GrepMatch] {
  let matches : Array[GrepMatch] = []
  for line in stdout.split("\n") {
    match parse_rg_line(line.to_owned()) {
      Some(m) => matches.push(m)
      None => ()
    }
  }
  matches
}

///|
priv struct JsRgSearcher {
  ignores : Array[String]
}

///|
/// Tier 1: delegate the search to a validated ripgrep binary.
impl GrepSearcher for JsRgSearcher with fn search(
  self : JsRgSearcher,
  pattern : String,
  base : String,
  file_glob : String,
  case_insensitive : Bool,
  use_regex : Bool,
) -> Array[GrepMatch] {
  match probe_rg() {
    Some(bin) => {
      let argv = build_rg_args(
        bin,
        pattern,
        base,
        file_glob,
        case_insensitive,
        use_regex,
        self.ignores,
      )
      let result = js_spawn_result(argv)
      // rg exit codes: 0 = matches found, 1 = no matches, 2 = error.
      if result.exit_code == 2 {
        raise @posoco.RuntimeError::InvocationFailed(
          "grep: rg error for '\{@devkit.sanitize_path(base)}': " +
          result.stderr,
        )
      }
      parse_rg_stdout(result.stdout)
    }
    None =>
      GrepSearcher::search(
        JsWalkGrepSearcher::{ ignores: self.ignores, },
        pattern,
        base,
        file_glob,
        case_insensitive,
        use_regex,
      )
  }
}

// Tier 2: in-process walker over node:fs (mirrors the native engine).

///|
/// Opaque node Stats handle; only the inline-JS envelope touches it.
#external
priv type FsStats

///|
#module("node:fs")
extern "js" fn fs_readdir_sync(path : String) -> FixedArray[String] = "readdirSync"

///|
#module("node:fs")
extern "js" fn fs_stat_sync(path : String) -> FsStats = "statSync"

///|
#module("node:fs")
extern "js" fn fs_read_text_sync(path : String, encoding : String) -> String = "readFileSync"

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
extern "js" fn js_stat_envelope(
  stat : (String) -> FsStats,
  path : String,
) -> String =
  #| (stat, path) => {
  #|   try {
  #|     const st = stat(path);
  #|     return JSON.stringify({ ok: true, dir: st.isDirectory() });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_read_file_envelope(
  read_text : (String, String) -> String,
  path : String,
) -> String =
  #| (readText, path) => {
  #|   try { return JSON.stringify({ ok: true, text: readText(path, "utf8") }); }
  #|   catch { return JSON.stringify({ ok: false }); }
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
fn js_is_directory(path : String) -> Bool? {
  let envelope : Json = @json.parse(js_stat_envelope(fs_stat_sync, path)) catch {
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
fn js_read_file_text(path : String) -> String? {
  let envelope : Json = @json.parse(
    js_read_file_envelope(fs_read_text_sync, path),
  ) catch {
    _ => return None
  }
  let fields = match envelope {
    Json::Object(fields) => fields
    _ => return None
  }
  match (fields.get("ok"), fields.get("text")) {
    (Some(Json::True), Some(Json::String(text))) => Some(text)
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
priv struct JsWalkGrepSearcher {
  ignores : Array[String]
}

///|
/// Recursive scan sharing the native engine's skip rules: hidden entries,
/// ignore names, binary extensions, NUL sniff, and U+FFFD (node's readFileSync
/// replaces invalid UTF-8 instead of throwing, so replacement chars mark a
/// binary decode).
impl GrepSearcher for JsWalkGrepSearcher with fn search(
  self : JsWalkGrepSearcher,
  pattern : String,
  base : String,
  file_glob : String,
  case_insensitive : Bool,
  use_regex : Bool,
) -> Array[GrepMatch] {
  let results : Array[GrepMatch] = []
  let match_line = grep_line_matcher(pattern, case_insensitive, use_regex)
  js_walk_grep_dir(self.ignores, match_line, file_glob, base, base, "", results) catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "grep: walk failed for '\{@devkit.sanitize_path(base)}'",
      )
  }
  results
}

///|
/// One recursion step over `dir` (whose path relative to the scan base is
/// `rel`); a failed base read raises, everything else skips quietly.
fn js_walk_grep_dir(
  ignores : Array[String],
  match_line : (StringView) -> Bool,
  file_glob : String,
  base : String,
  dir : String,
  rel : String,
  out : Array[GrepMatch],
) -> Unit raise @posoco.RuntimeError {
  let entries = match js_readdir_entries(dir) {
    Some(entries) => entries
    None =>
      if dir == base {
        raise @posoco.RuntimeError::InvocationFailed(
          "grep: walk failed for '\{@devkit.sanitize_path(base)}'",
        )
      } else {
        return
      }
  }
  for entry in entries {
    if entry.has_prefix(".") {
      continue
    }
    let entry_rel = if rel == "" { entry } else { "\{rel}/\{entry}" }
    if @devkit.matches_ignore(entry_rel, ignores) {
      continue
    }
    let entry_full = js_path_join(dir, entry)
    match js_is_directory(entry_full) {
      Some(true) =>
        js_walk_grep_dir(
          ignores, match_line, file_glob, base, entry_full, entry_rel, out,
        )
      _ => {
        if file_glob != "" && !js_grep_glob_matches(file_glob, entry_rel) {
          continue
        }
        if is_binary_extension(entry_full) {
          continue
        }
        let text = match js_read_file_text(entry_full) {
          Some(text) => text
          None => continue
        }
        if looks_binary(text) || text.contains("\u{FFFD}") {
          continue
        }
        let mut line_num = 0
        for line in text.split("\n") {
          line_num += 1
          if match_line(line) {
            out.push(GrepMatch::{
              path: entry_full,
              line: line_num,
              content: line.to_owned(),
            })
          }
        }
      }
    }
  }
}

///|
/// Same file-filter rule as the native engine: a glob with "/" matches the
/// base-relative path, a bare name pattern matches the basename.
fn js_grep_glob_matches(file_glob : String, rel : String) -> Bool {
  if file_glob.contains("/") {
    return @devkit.glob_match(file_glob, rel)
  }
  let mut last = rel
  match rel.rev_find("/") {
    Some(idx) => last = rel[idx + 1:].to_owned()
    None => ()
  }
  @devkit.glob_match(file_glob, last)
}

///|
pub impl @posoco.ToolProvider for GrepTools with fn list_tools(
  _self : GrepTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `grep` tool on js. Business logic lives in the shared
/// `execute_grep_impl`; this method only supplies the engine ladder.
pub impl @posoco.ToolProvider for GrepTools with fn execute(
  self : GrepTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let call : @posoco.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }
  execute_grep_impl(JsRgSearcher::{ ignores: self.ignores, }, self.anchor, call)
}

///|
pub extend GrepTools with @posoco.ToolProvider::{list_tools}
