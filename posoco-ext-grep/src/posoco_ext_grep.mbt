///|
/// GrepTools — content search tool provider.
///
/// Engines share one contract: literal matching by default with opt-in
/// `regex` search, hidden entries and `ignores` directories pruned,
/// binary-looking files skipped, and an optional `glob` filter restricting
/// which files are searched. Regex flavor: the js ripgrep path uses ripgrep
/// syntax, the walker engines use `moonbitlang/regexp`; the common core
/// (alternation, classes, quantifiers, anchors, groups) agrees across both
/// and every engine matches line-wise. On native the engine is an in-process
/// walker (`@fs.walk` + per-line matcher). On js (bun) the engine ladder is
/// ripgrep first (validated via `rg --version`, so a grep shim on PATH is
/// rejected), falling back to an in-process node:fs walker when no real rg
/// is found. On wasm-gc the tool is not listed and execute raises
/// `RuntimeError::InvocationFailed`.
pub(all) struct GrepTools {
  // Resolves the search base against the workspace root; None leaves the
  // base on the process working directory.
  anchor : @devkit.WorkspaceAnchor?
  // Directory/file names pruned during traversal; defaults to
  // @devkit.default_ignore_patterns(). Hidden entries are always skipped.
  ignores : Array[String]
}

///|
/// Canonical constructor.
pub fn GrepTools::GrepTools(
  anchor~ : @devkit.WorkspaceAnchor? = None,
  ignores~ : Array[String] = @devkit.default_ignore_patterns(),
) -> GrepTools {
  GrepTools::{ anchor, ignores, }
}

///|
/// What the tool returns for each file with matches.
priv enum GrepOutputMode {
  Content
  FilesWithMatches
  Count
}

///|
/// One content match: engine-native `path` (as spelled from the base),
/// 1-indexed `line`, raw line text.
priv struct GrepMatch {
  path : String
  line : Int32
  content : String
}

///|
/// High-level content-search boundary.
///
/// Engines return flat `GrepMatch` lists; the shared impl derives the three
/// output modes, caps, and formatting from them. `ignores` lives on the
/// searcher so both engines prune identically.
priv trait GrepSearcher {
  async fn search(
    self : Self,
    pattern : String,
    base : String,
    file_glob : String,
    case_insensitive : Bool,
    use_regex : Bool,
  ) -> Array[GrepMatch] raise @posoco.RuntimeError
}

///|
/// One per-line predicate shared by the walker engines. Regex mode compiles
/// once per search (`i` flag rides `case_insensitive`); an invalid pattern
/// fails the whole search loudly instead of silently matching nothing.
fn grep_line_matcher(
  pattern : String,
  case_insensitive : Bool,
  use_regex : Bool,
) -> ((StringView) -> Bool) raise @posoco.RuntimeError {
  if use_regex {
    let flags = if case_insensitive { "i" } else { "" }
    let re = @regexp.compile(pattern, flags~) catch {
      error =>
        raise @posoco.RuntimeError::InvocationFailed(
          "grep: invalid regex '\{pattern}': \{error.to_string()}",
        )
    }
    fn(line) { re.match_(line) is Some(_) }
  } else if case_insensitive {
    let needle = pattern.to_lower()
    fn(line) { line.to_lower().contains(needle) }
  } else {
    fn(line) { line.contains(pattern) }
  }
}

///|
/// Default cap on returned entries (match lines for content mode, file
/// entries for the other modes).
const GREP_DEFAULT_MAX_MATCHES = 100

///|
/// File extensions searched never; anything else decodes as text.
fn is_binary_extension(path : String) -> Bool {
  let lower = path.to_lower()
  for
    ext in [
      ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".bmp", ".tiff", ".zip",
      ".gz", ".tar", ".tgz", ".bz2", ".xz", ".7z", ".rar", ".exe", ".dll", ".so",
      ".dylib", ".a", ".o", ".bin", ".wasm", ".mp3", ".mp4", ".avi", ".mov", ".wav",
      ".flac", ".ogg", ".mkv", ".webm", ".ttf", ".otf", ".woff", ".woff2", ".eot",
      ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".db", ".sqlite",
      ".sqlite3", ".parquet", ".pyc", ".class", ".jar", ".node",
    ] {
    if lower.has_suffix(ext) {
      return true
    }
  }
  false
}

///|
/// NUL byte anywhere in the first chunk marks a binary file (rg parity).
fn looks_binary(content : String) -> Bool {
  let probe = if content.length() > 8000 { content[:8000] } else { content[:] }
  probe.contains("\u{0}")
}

///|
/// Max characters per rendered match line before truncation (char-boundary
/// safe), matching the read tool.
const GREP_LINE_CHAR_CAP = 1200

///|
/// Max formatted bytes of the match body before the page is cut, matching
/// the read tool.
const GREP_BYTE_CAP = 40_000

///|
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("grep"),
      description: "Literal file search; set `regex: true` to match a regular expression instead. Content mode returns file headers plus `line|text`; other modes return matching paths or counts. Skips hidden/ignored/binary files. For syntax-shaped code queries (definitions, call sites, AST patterns in source), prefer astgrep.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "pattern": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Literal search text, or a regular expression when `regex` is true",
            ),
          }),
          "regex": Json::object({
            "type": Json::string("boolean"),
            "description": Json::string(
              "Treat pattern as a regular expression; default false = literal text",
            ),
          }),
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Search path; default '.'"),
          }),
          "glob": Json::object({
            "type": Json::string("string"),
            "description": Json::string("File glob, e.g. '*.mbt'"),
          }),
          "output_mode": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "content (default), files_with_matches, or count",
            ),
          }),
          "case_insensitive": Json::object({
            "type": Json::string("boolean"),
            "description": Json::string("Ignore case; default false"),
          }),
          "max_matches": Json::object({
            "type": Json::string("integer"),
            "description": Json::string("Returned entry cap; default 100"),
          }),
        }),
        "required": Json::array([Json::string("pattern")]),
      }),
      owner: @posoco.OwnerId::unchecked("posoco_ext_grep"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_grep"),
    },
  ]
}

///|
/// Extract `(pattern, base, file_glob, mode, case_insensitive, use_regex,
/// max_matches)` from ToolCall arguments. Wrong types and bad values are
/// loud; `base` defaults to "." and `file_glob` to "" (no filter).
fn extract_grep_args(
  args : Json,
) -> (String, String, String, GrepOutputMode, Bool, Bool, Int32) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let p = match obj.get("pattern") {
        Some(String(s)) =>
          if s == "" {
            raise @posoco.RuntimeError::UnknownTool(
              "grep: 'pattern' must be non-empty",
            )
          } else {
            s
          }
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: 'pattern' must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("grep: missing 'pattern'")
      }
      let b = match obj.get("path") {
        Some(String(s)) => s
        None => "."
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: 'path' must be a string",
          )
      }
      let g = match obj.get("glob") {
        Some(String(s)) => s
        None => ""
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: 'glob' must be a string",
          )
      }
      let mode = match obj.get("output_mode") {
        None | Some(Null) => Content
        Some(String(s)) =>
          match s {
            "content" => Content
            "files_with_matches" => FilesWithMatches
            "count" => Count
            other =>
              raise @posoco.RuntimeError::UnknownTool(
                "grep: invalid output_mode '\{other}'",
              )
          }
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: 'output_mode' must be a string",
          )
      }
      let ci = match obj.get("case_insensitive") {
        None | Some(Null) => false
        Some(True) => true
        Some(False) => false
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: 'case_insensitive' must be boolean",
          )
      }
      let use_regex = match obj.get("regex") {
        None | Some(Null) => false
        Some(True) => true
        Some(False) => false
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: 'regex' must be boolean",
          )
      }
      let max = match obj.get("max_matches") {
        None | Some(Null) => GREP_DEFAULT_MAX_MATCHES
        Some(Number(n, ..)) => {
          let v = n.to_int()
          if v <= 0 {
            raise @posoco.RuntimeError::UnknownTool(
              "grep: 'max_matches' must be > 0",
            )
          }
          v
        }
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: 'max_matches' must be an integer",
          )
      }
      (p, b, g, mode, ci, use_regex, max)
    }
    _ => raise @posoco.RuntimeError::UnknownTool("grep: invalid arguments")
  }
}

///|
/// Render one compact grouped match line as `line|text`.
fn render_match_line(m : GrepMatch) -> String {
  let content = if m.content.length() > GREP_LINE_CHAR_CAP {
    @devkit.truncate_chars(m.content, GREP_LINE_CHAR_CAP) + "…[cut]"
  } else {
    m.content
  }
  "\{m.line}|\{content}"
}

///|
/// Render content mode: file headers with indented match lines. Returns the
/// body, the number of match lines shown, and whether the byte cap cut the
/// page short. The first line is always allowed; prefix bytes and truncation
/// markers count toward the budget.
fn render_content_body(
  matches : Array[GrepMatch],
  max_matches : Int32,
) -> (String, Int32, Bool) {
  let out = StringBuilder()
  let mut shown = 0
  let mut bytes = 0
  let mut byte_cut = false
  let mut last_path = ""
  for m in matches {
    if shown >= max_matches {
      break
    }
    let rendered = render_match_line(m)
    let header_bytes = if m.path == last_path {
      0
    } else {
      @utf8.encode(m.path).length() + 1
    }
    let line_bytes = @utf8.encode(rendered).length() + 1
    if shown > 0 && bytes + header_bytes + line_bytes > GREP_BYTE_CAP {
      byte_cut = true
      break
    }
    if m.path != last_path {
      out.write_string(m.path)
      out.write_char('\n')
      bytes += header_bytes
      last_path = m.path
    }
    out.write_string(rendered)
    out.write_char('\n')
    bytes += line_bytes
    shown += 1
  }
  (out.to_string(), shown, byte_cut)
}

///|
/// Distinct paths of `matches` in first-appearance order.
fn distinct_paths(matches : Array[GrepMatch]) -> Array[String] {
  let seen : Map[String, Unit] = Map::from_array([])
  for m in matches {
    if !seen.contains(m.path) {
      seen[m.path] = ()
    }
  }
  let paths : Array[String] = []
  for path, _ in seen {
    paths.push(path)
  }
  paths
}

///|
/// Match count per distinct path in first-appearance order.
fn match_counts(matches : Array[GrepMatch]) -> Array[(String, Int32)] {
  let counts : Map[String, Int32] = Map::from_array([])
  for m in matches {
    counts[m.path] = match counts.get(m.path) {
      Some(n) => n + 1
      None => 1
    }
  }
  let entries : Array[(String, Int32)] = []
  for path, n in counts {
    entries.push((path, n))
  }
  entries
}

///|
fn grep_summary(count : Int32, noun : String) -> String {
  if count == 0 {
    "no matches"
  } else {
    "\{count} \{noun}"
  }
}

///|
/// Structured payload for observers/UIs; never sent to the model. Carries
/// the reserved `summary` field plus the total count and truncation flag.
fn grep_structured(count : Int32, noun : String, truncated : Bool) -> Json {
  Json::object(
    Map::from_array([
      ("summary", Json::string(grep_summary(count, noun))),
      ("count", Json::number(count.to_double())),
      ("truncated", Json::boolean(truncated)),
    ]),
  )
}

///|
/// Build the model-visible output for a mode from the full match list.
/// Header counts are totals; the body lists at most `max_matches` entries;
/// a footer reports the remainder when anything was cut.
fn grep_result_text(
  mode : GrepOutputMode,
  matches : Array[GrepMatch],
  _pattern : String,
  max_matches : Int32,
) -> (String, Int32, Bool) {
  if matches.length() == 0 {
    return ("(no matches)", 0, false)
  }
  match mode {
    Content => {
      let (body, shown, byte_cut) = render_content_body(matches, max_matches)
      let total = matches.length()
      let truncated = byte_cut || shown < total
      let mut text = body.trim_end(chars="\n").to_owned()
      if truncated {
        text = "\{text}\n… +\{total - shown} matches"
      }
      (text, total, truncated)
    }
    FilesWithMatches => {
      let paths = distinct_paths(matches)
      let total = paths.length()
      let shown = if total < max_matches { total } else { max_matches }
      let builder = StringBuilder()
      for i in 0..<shown {
        builder.write_string(paths[i])
        builder.write_char('\n')
      }
      let mut text = builder.to_string().trim_end(chars="\n").to_owned()
      if shown < total {
        text = "\{text}\n… +\{total - shown} files"
      }
      (text, total, shown < total)
    }
    Count => {
      let counts = match_counts(matches)
      let total = counts.length()
      let shown = if total < max_matches { total } else { max_matches }
      let builder = StringBuilder()
      for i in 0..<shown {
        let (path, n) = counts[i]
        builder.write_string("\{path}:\{n}")
        builder.write_char('\n')
      }
      let mut text = builder.to_string().trim_end(chars="\n").to_owned()
      if shown < total {
        text = "\{text}\n… +\{total - shown} files"
      }
      (text, total, shown < total)
    }
  }
}

///|
/// Rewrite a match `path` produced under `resolved` back to the `raw_base`
/// spelling (no prefix when the base was the default "."). Paths that do not
/// carry the resolved prefix pass through unchanged.
fn rebase_match_path(
  path : String,
  resolved : String,
  raw_base : String,
) -> String {
  let prefix = if resolved == "/" { "/" } else { "\{resolved}/" }
  if !path.has_prefix(prefix) {
    return path
  }
  let rest = path[prefix.length():].to_owned()
  if raw_base == "." || raw_base == "" {
    rest
  } else {
    "\{raw_base}/\{rest}"
  }
}

///|
/// Shared `grep` execute logic. Target-agnostic; only the searcher differs.
///
/// When anchored, the search runs in the resolved directory and match paths
/// are re-anchored to the argument spelling, so the workspace root never
/// leaks into model-visible output.
async fn execute_grep_impl(
  searcher : &GrepSearcher,
  anchor : @devkit.WorkspaceAnchor?,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (
    pattern,
    raw_base,
    file_glob,
    mode,
    case_insensitive,
    use_regex,
    max_matches,
  ) = extract_grep_args(call.arguments)
  let matches = match anchor {
    Some(anchor) => {
      let resolved = anchor.resolve(raw_base)
      let found = searcher.search(
        pattern, resolved, file_glob, case_insensitive, use_regex,
      )
      [
        for m in found => {
          GrepMatch::{
            path: rebase_match_path(
              @devkit.strip_dot_prefix(m.path),
              resolved,
              raw_base,
            ),
            line: m.line,
            content: m.content,
          }
        }
      ]
    }
    None => {
      let found = searcher.search(
        pattern, raw_base, file_glob, case_insensitive, use_regex,
      )
      [
        for m in found => {
          GrepMatch::{
            path: @devkit.strip_dot_prefix(m.path),
            line: m.line,
            content: m.content,
          }
        }
      ]
    }
  }
  let (text, count, truncated) = grep_result_text(
    mode, matches, pattern, max_matches,
  )
  let noun = match mode {
    Content => "matches"
    FilesWithMatches => "files"
    Count => "files"
  }
  @posoco.ToolOutcome::Success(
    content=text,
    structured=Some(grep_structured(count, noun, truncated)),
  )
}
