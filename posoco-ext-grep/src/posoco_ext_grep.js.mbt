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
/// Stream ripgrep stdout and aggregate matches as they arrive. Only bounded
/// output is serialized back to MoonBit; full stdout is never retained.
extern "js" fn js_spawn_grep_envelope(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> NodeProc,
  cmd : FixedArray[String],
  mode : Int32,
  max_matches : Int32,
  line_cap : Int32,
  byte_cap : Int32,
  resolved_prefix : String,
  raw_base : String,
) -> @js_async.Promise[String] =
  #| async (spawn, cmd, mode, maxMatches, lineCap, byteCap, resolvedPrefix, rawBase) => {
  #|   const proc = spawn(cmd[0], cmd.slice(1), { stdio: ["ignore", "pipe", "pipe"] })
  #|   const matches = [], paths = [], counts = []
  #|   let totalMatches = 0, totalFiles = 0, lastPath = "", lastPathStored = false
  #|   let storedBytes = 0, contentByteCut = false
  #|   let pendingPath = "", pendingLine = "", readingPath = true, lineOverflow = false
  #|   const lineBufferLimit = lineCap * 2 + 128
  #|   const normalizePath = (rawPath) => {
  #|     const clean = rawPath.startsWith("./") ? rawPath.slice(2) : rawPath
  #|     if (resolvedPrefix && clean.startsWith(resolvedPrefix)) {
  #|       const rest = clean.slice(resolvedPrefix.length)
  #|       return rawBase === "." || rawBase === "" ? rest : rawBase + "/" + rest
  #|     }
  #|     return clean
  #|   }
  #|   const processRecord = (rawPath, raw, overflow) => {
  #|     const sep = raw.indexOf(":")
  #|     if (sep <= 0) return
  #|     const lineNo = Number(raw.slice(0, sep))
  #|     if (!Number.isSafeInteger(lineNo) || lineNo <= 0) return
  #|     const path = normalizePath(rawPath)
  #|     totalMatches++
  #|     if (mode === 0) {
  #|       if (matches.length >= maxMatches || contentByteCut) return
  #|       const rawContent = raw.slice(sep + 1)
  #|       const chars = Array.from(rawContent)
  #|       const cut = overflow || chars.length > lineCap
  #|       const content = cut ? chars.slice(0, lineCap).join("") : rawContent
  #|       const rendered = String(lineNo) + "|" + content + (cut ? "…[cut]" : "")
  #|       const headerBytes = matches.length === 0 || matches[matches.length - 1].path !== path
  #|         ? Buffer.byteLength(path, "utf8") + 1 : 0
  #|       const lineBytes = Buffer.byteLength(rendered, "utf8") + 1
  #|       if (matches.length === 0 || storedBytes + headerBytes + lineBytes <= byteCap) {
  #|         matches.push({ path, line: lineNo, content, contentTruncated: cut })
  #|         storedBytes += headerBytes + lineBytes
  #|       } else contentByteCut = true
  #|     } else if (path !== lastPath) {
  #|       totalFiles++
  #|       lastPath = path
  #|       lastPathStored = paths.length < maxMatches
  #|       if (lastPathStored) {
  #|         paths.push(path)
  #|         if (mode === 2) counts.push(1)
  #|       }
  #|     } else if (mode === 2 && lastPathStored) {
  #|       counts[counts.length - 1]++
  #|     }
  #|   }
  #|   const consumeChunk = (chunk) => {
  #|     let pos = 0
  #|     while (pos < chunk.length) {
  #|       if (readingPath) {
  #|         const nul = chunk.indexOf("\0", pos)
  #|         const nl = chunk.indexOf("\n", pos)
  #|         if (nl >= 0 && (nul < 0 || nl < nul)) {
  #|           pendingPath = ""
  #|           pos = nl + 1
  #|           continue
  #|         }
  #|         if (nul < 0) { pendingPath += chunk.slice(pos); return }
  #|         pendingPath += chunk.slice(pos, nul)
  #|         pendingLine = ""; lineOverflow = false; readingPath = false; pos = nul + 1
  #|       } else {
  #|         const nl = chunk.indexOf("\n", pos)
  #|         const end = nl < 0 ? chunk.length : nl
  #|         const part = chunk.slice(pos, end)
  #|         const remaining = Math.max(0, lineBufferLimit - pendingLine.length)
  #|         if (remaining > 0) pendingLine += part.slice(0, remaining)
  #|         if (part.length > remaining) lineOverflow = true
  #|         if (nl < 0) return
  #|         processRecord(pendingPath, pendingLine, lineOverflow)
  #|         pendingPath = ""; pendingLine = ""; lineOverflow = false; readingPath = true; pos = nl + 1
  #|       }
  #|     }
  #|   }
  #|   const stdoutDone = new Promise((resolve) => {
  #|     if (!proc.stdout) return resolve()
  #|     let finished = false
  #|     const finish = () => {
  #|       if (finished) return
  #|       finished = true
  #|       if (!readingPath && pendingLine.length > 0) processRecord(pendingPath, pendingLine, lineOverflow)
  #|       resolve()
  #|     }
  #|     proc.stdout.setEncoding("utf8")
  #|     proc.stdout.on("data", consumeChunk)
  #|     proc.stdout.on("end", finish); proc.stdout.on("close", finish); proc.stdout.on("error", finish)
  #|   })
  #|   let stderr = ""
  #|   const stderrDone = new Promise((resolve) => {
  #|     if (!proc.stderr) return resolve("")
  #|     const finish = () => resolve(stderr)
  #|     proc.stderr.setEncoding("utf8")
  #|     proc.stderr.on("data", (chunk) => {
  #|       if (stderr.length < 4096) stderr += chunk.slice(0, 4096 - stderr.length)
  #|     })
  #|     proc.stderr.on("end", finish); proc.stderr.on("close", finish); proc.stderr.on("error", finish)
  #|   })
  #|   const exitDone = new Promise((resolve) => {
  #|     proc.on("close", (code) => resolve(code ?? -1))
  #|     proc.on("error", () => resolve(-1))
  #|   })
  #|   const [exitCode, stderrText] = await Promise.all([exitDone, stderrDone, stdoutDone])
  #|     .then(([code, errorText]) => [code, errorText])
  #|   return JSON.stringify({ exitCode, stderr: stderrText, totalMatches, totalFiles, matches, paths, counts, contentByteCut })
  #| }

///|
priv struct JsSpawnResult {
  exit_code : Int32
  stdout : String
}

///|
async fn js_spawn_result(cmd : Array[String]) -> JsSpawnResult noraise {
  let json : Json = @json.parse(
    js_spawn_envelope(cp_spawn, FixedArray::from_array(cmd)).wait(),
  ) catch {
    _ => return { exit_code: 2, stdout: "", }
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ => return { exit_code: 2, stdout: "", }
  }
  let exit_code = match fields.get("exitCode") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 2
  }
  let stdout = match fields.get("stdout") {
    Some(Json::String(text)) => text
    _ => ""
  }
  { exit_code, stdout, }
}

///|
priv struct JsGrepSpawnResult {
  exit_code : Int32
  stderr : String
  search_result : GrepSearchResult
}

///|
fn rg_mode_code(mode : GrepOutputMode) -> Int32 {
  match mode {
    Content => 0
    FilesWithMatches => 1
    Count => 2
  }
}

///|
async fn js_spawn_grep_result(
  cmd : Array[String],
  mode : GrepOutputMode,
  max_matches : Int32,
  path_mapper : GrepPathMapper,
) -> JsGrepSpawnResult noraise {
  let resolved_prefix = match path_mapper.resolved {
    Some("/") => "/"
    Some(resolved) => "\{resolved}/"
    None => ""
  }
  let json : Json = @json.parse(
    js_spawn_grep_envelope(
      cp_spawn,
      FixedArray::from_array(cmd),
      rg_mode_code(mode),
      max_matches,
      GREP_LINE_CHAR_CAP,
      GREP_BYTE_CAP,
      resolved_prefix,
      path_mapper.raw_base,
    ).wait(),
  ) catch {
    _ =>
      return {
        exit_code: 2,
        stderr: "ripgrep stream envelope decode failed",
        search_result: {
          matches: [],
          paths: [],
          counts: [],
          total_matches: 0,
          total_files: 0,
          content_byte_cut: false,
        },
      }
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ =>
      return {
        exit_code: 2,
        stderr: "ripgrep stream envelope is not an object",
        search_result: {
          matches: [],
          paths: [],
          counts: [],
          total_matches: 0,
          total_files: 0,
          content_byte_cut: false,
        },
      }
  }
  let exit_code = match fields.get("exitCode") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 2
  }
  let stderr = match fields.get("stderr") {
    Some(Json::String(value)) => value
    _ => ""
  }
  let total_matches = match fields.get("totalMatches") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 0
  }
  let total_files = match fields.get("totalFiles") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 0
  }
  let content_byte_cut = fields.get("contentByteCut") is Some(Json::True)
  let matches : Array[GrepMatch] = []
  match fields.get("matches") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::Object(item_fields) => {
            let path = match item_fields.get("path") {
              Some(Json::String(value)) => value
              _ => ""
            }
            let line = match item_fields.get("line") {
              Some(Json::Number(value, ..)) => value.to_int()
              _ => 0
            }
            let content = match item_fields.get("content") {
              Some(Json::String(value)) => value
              _ => ""
            }
            let content_truncated = item_fields.get("contentTruncated")
              is Some(Json::True)
            matches.push(GrepMatch::{ path, line, content, content_truncated, })
          }
          _ => ()
        }
      }
    _ => ()
  }
  let paths : Array[String] = []
  match fields.get("paths") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::String(value) => paths.push(value)
          _ => ()
        }
      }
    _ => ()
  }
  let counts : Array[Int32] = []
  match fields.get("counts") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::Number(value, ..) => counts.push(value.to_int())
          _ => ()
        }
      }
    _ => ()
  }
  {
    exit_code,
    stderr,
    search_result: {
      matches,
      paths,
      counts,
      total_matches,
      total_files,
      content_byte_cut,
    },
  }
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
priv struct JsRgSearcher {
  ignores : Array[String]
}

///|
/// Tier 1: delegate to validated ripgrep. Stdout is parsed incrementally and
/// only bounded output entries are sent back to MoonBit.
impl GrepSearcher for JsRgSearcher with fn search(
  self : JsRgSearcher,
  pattern : String,
  base : String,
  file_glob : String,
  case_insensitive : Bool,
  use_regex : Bool,
  mode : GrepOutputMode,
  max_matches : Int32,
  path_mapper : GrepPathMapper,
) -> GrepSearchResult {
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
      let result = js_spawn_grep_result(argv, mode, max_matches, path_mapper)
      if result.exit_code < 0 || result.exit_code > 1 {
        raise @posoco.RuntimeError::InvocationFailed(
          "grep: rg error for '\{@devkit.sanitize_path(base)}': " +
          result.stderr,
        )
      }
      result.search_result
    }
    None =>
      GrepSearcher::search(
        JsWalkGrepSearcher::{ ignores: self.ignores, },
        pattern,
        base,
        file_glob,
        case_insensitive,
        use_regex,
        mode,
        max_matches,
        path_mapper,
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
  mode : GrepOutputMode,
  max_matches : Int32,
  path_mapper : GrepPathMapper,
) -> GrepSearchResult {
  let state = new_grep_search_state(mode, max_matches, path_mapper)
  let match_line = grep_line_matcher(pattern, case_insensitive, use_regex)
  js_walk_grep_dir(self.ignores, match_line, file_glob, base, base, "", state) catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "grep: walk failed for '\{@devkit.sanitize_path(base)}'",
      )
  }
  finish_grep_search(state)
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
  state : Ref[GrepSearchState],
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
          ignores, match_line, file_glob, base, entry_full, entry_rel, state,
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
            grep_record_match(state, entry_full, line_num, line.to_owned())
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
