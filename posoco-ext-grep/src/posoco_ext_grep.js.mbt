// js (bun) target: engine ladder for content search.
//
// Tier 1 — ripgrep when a *real* rg is found: PATH via Bun.which, then the
// common Homebrew prefixes. Candidates are validated by spawning
// `rg --version` and checking the banner, so a grep shim on PATH (observed
// in the wild) is rejected rather than failing on rg-only flags.
// Tier 2 — an in-process walker over node:fs with the same semantics as the
// native engine (literal match, hidden/ignore pruning, binary skip).
//
// Pinned rg semantics for cross-target parity with the walker:
// --no-ignore + explicit --glob excludes for the ignore list (no .gitignore
// reading), hidden entries skipped (rg default), -F literal matching.
// Spawns are async and drained via Response(...).text(), bridged with
// @js_async. The spawn result crosses the FFI as one JSON string envelope
// (see posoco-ext-read's js adaptor and docs/questions.md 2026-08-19).

///|
extern "js" fn bun_which(name : String) -> String =
  #| (name) => Bun.which(name) ?? ""

///|
/// Spawn with piped streams and await exit + both drains concurrently.
extern "js" fn js_spawn_envelope(
  cmd : Array[String],
) -> @js_async.Promise[String] =
  #| async (cmd) => {
  #|   const proc = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe" });
  #|   const [exitCode, stdout, stderr] = await Promise.all([
  #|     proc.exited,
  #|     new Response(proc.stdout).text(),
  #|     new Response(proc.stderr).text(),
  #|   ]);
  #|   return JSON.stringify({ ok: true, exitCode, stdout, stderr });
  #| }

///|
/// Decoded spawn envelope.
priv struct JsSpawnResult {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
/// Await the spawn envelope. `noraise`: both the JSON parse and the promise
/// rejection are caught here, so callers see a plain envelope value.
async fn js_spawn_result(cmd : Array[String]) -> JsSpawnResult noraise {
  let json : Json = @json.parse(js_spawn_envelope(cmd).wait()) catch {
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
/// Candidate rg locations: PATH first, then the common Homebrew prefixes.
fn rg_candidates() -> Array[String] {
  let candidates : Array[String] = []
  let on_path = bun_which("rg")
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
/// via -e (safe against leading `-`), fixed strings, hidden skip is the rg
/// default, and the ignore list rides in as negated globs.
fn build_rg_args(
  bin : String,
  pattern : String,
  base : String,
  file_glob : String,
  case_insensitive : Bool,
  ignores : Array[String],
) -> Array[String] {
  let args : Array[String] = [
    bin, "--line-number", "--color=never", "--no-heading", "--no-ignore", "--null",
    "-F",
  ]
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
) -> Array[GrepMatch] {
  match probe_rg() {
    Some(bin) => {
      let argv = build_rg_args(
        bin,
        pattern,
        base,
        file_glob,
        case_insensitive,
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
      )
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Tier 2: in-process walker over node:fs (mirrors the native engine).
// ──────────────────────────────────────────────────────────────────────────

///|
extern "js" fn js_readdir_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { return JSON.stringify({ ok: true, entries: fs.readdirSync(path) }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_stat_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try {
  #|     const st = fs.statSync(path);
  #|     return JSON.stringify({ ok: true, dir: st.isDirectory() });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_read_file_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { return JSON.stringify({ ok: true, text: fs.readFileSync(path, "utf8") }); }
  #|   catch { return JSON.stringify({ ok: false }); }
  #| }

///|
/// Decode a `{ok, entries}` envelope; None means the directory could not be
/// read.
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
/// Decode a `{ok, dir}` envelope; None means the stat failed.
fn js_is_directory(path : String) -> Bool? {
  let envelope : Json = @json.parse(js_stat_envelope(path)) catch {
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
/// Decode a `{ok, text}` envelope; None means the read failed.
fn js_read_file_text(path : String) -> String? {
  let envelope : Json = @json.parse(js_read_file_envelope(path)) catch {
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
) -> Array[GrepMatch] {
  let results : Array[GrepMatch] = []
  let needle = if case_insensitive { pattern.to_lower() } else { pattern }
  js_walk_grep_dir(
    self.ignores,
    pattern,
    needle,
    case_insensitive,
    file_glob,
    base,
    base,
    "",
    results,
  ) catch {
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
  pattern : String,
  needle : String,
  case_insensitive : Bool,
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
          ignores, pattern, needle, case_insensitive, file_glob, base, entry_full,
          entry_rel, out,
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
          let hit = if case_insensitive {
            line.to_lower().contains(needle)
          } else {
            line.contains(pattern)
          }
          if hit {
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
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_grep_impl(JsRgSearcher::{ ignores: self.ignores, }, self.anchor, call)
}
