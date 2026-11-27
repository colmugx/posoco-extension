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
  content_truncated : Bool
}

///|
priv struct GrepSearchResult {
  matches : Array[GrepMatch]
  paths : Array[String]
  counts : Array[Int32]
  total_matches : Int32
  total_files : Int32
  content_byte_cut : Bool
}

///|
/// Rewrites raw engine paths into display paths (stripping leading `./` and
/// rebasing anchored results) before collection and byte-budget accounting.
priv struct GrepPathMapper {
  resolved : String?
  raw_base : String
}

///|
fn GrepPathMapper::map(self : GrepPathMapper, path : String) -> String {
  let clean = @devkit.strip_dot_prefix(path)
  match self.resolved {
    Some(resolved) => rebase_match_path(clean, resolved, self.raw_base)
    None => clean
  }
}

///|
/// High-level content-search boundary.
///
/// Engines aggregate matches into a bounded `GrepSearchResult` using the
/// shared mode, cap, and display-path mapping. `ignores` lives on the
/// searcher so all engines prune identically.
priv trait GrepSearcher {
  async fn search(
    self : Self,
    pattern : String,
    base : String,
    file_glob : String,
    case_insensitive : Bool,
    use_regex : Bool,
    mode : GrepOutputMode,
    max_matches : Int32,
    path_mapper : GrepPathMapper,
  ) -> GrepSearchResult raise @posoco.RuntimeError
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
    // ASCII needles keep the allocation-free path: an ASCII fold cannot widen a
    // match, so a non-ASCII line needs no folding to be compared.
    if @devkit.is_ascii(pattern) {
      let needle = pattern.to_lower()
      fn(line) { line.to_lower().contains(needle) }
    } else {
      let needle = @devkit.fold_case(pattern)
      fn(line) { @devkit.fold_case(line).contains(needle) }
    }
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
priv struct GrepSearchState {
  mode : GrepOutputMode
  max_matches : Int32
  path_mapper : GrepPathMapper
  matches : Array[GrepMatch]
  paths : Array[String]
  counts : Array[Int32]
  total_matches : Int32
  total_files : Int32
  last_path : String
  last_path_stored : Bool
  content_bytes : Int32
  content_byte_cut : Bool
}

///|
fn new_grep_search_state(
  mode : GrepOutputMode,
  max_matches : Int32,
  path_mapper : GrepPathMapper,
) -> Ref[GrepSearchState] {
  Ref(GrepSearchState::{
    mode,
    max_matches,
    path_mapper,
    matches: [],
    paths: [],
    counts: [],
    total_matches: 0,
    total_files: 0,
    last_path: "",
    last_path_stored: false,
    content_bytes: 0,
    content_byte_cut: false,
  })
}

///|
/// Retain only bounded output entries while continuing to count every match.
fn grep_record_match(
  state : Ref[GrepSearchState],
  raw_path : String,
  line : Int32,
  content : String,
) -> Unit {
  let current = state.val
  let path = current.path_mapper.map(raw_path)
  let total_matches = current.total_matches + 1
  match current.mode {
    Content => {
      let matches = current.matches
      let mut content_bytes = current.content_bytes
      let mut content_byte_cut = current.content_byte_cut
      if matches.length() < current.max_matches && !content_byte_cut {
        let clipped = @devkit.truncate_chars(content, GREP_LINE_CHAR_CAP)
        let content_truncated = clipped != content
        let rendered_content = if content_truncated {
          clipped + "…[cut]"
        } else {
          clipped
        }
        let rendered = "\{line}|\{rendered_content}"
        let header_bytes = if matches.length() == 0 ||
          matches[matches.length() - 1].path != path {
          @utf8.encode(path).length() + 1
        } else {
          0
        }
        let line_bytes = @utf8.encode(rendered).length() + 1
        if matches.length() == 0 ||
          content_bytes + header_bytes + line_bytes <= GREP_BYTE_CAP {
          matches.push(GrepMatch::{
            path,
            line,
            content: clipped,
            content_truncated,
          })
          content_bytes += header_bytes + line_bytes
        } else {
          content_byte_cut = true
        }
      }
      state.val = GrepSearchState::{
        mode: current.mode,
        max_matches: current.max_matches,
        path_mapper: current.path_mapper,
        matches,
        paths: current.paths,
        counts: current.counts,
        total_matches,
        total_files: current.total_files,
        last_path: current.last_path,
        last_path_stored: current.last_path_stored,
        content_bytes,
        content_byte_cut,
      }
    }
    FilesWithMatches | Count => {
      let paths = current.paths
      let counts = current.counts
      let mut total_files = current.total_files
      let mut last_path_stored = current.last_path_stored
      if path != current.last_path {
        total_files += 1
        last_path_stored = paths.length() < current.max_matches
        if last_path_stored {
          paths.push(path)
          if current.mode is Count {
            counts.push(1)
          }
        }
      } else if current.mode is Count && last_path_stored {
        let last = counts.length() - 1
        counts[last] = counts[last] + 1
      }
      state.val = GrepSearchState::{
        mode: current.mode,
        max_matches: current.max_matches,
        path_mapper: current.path_mapper,
        matches: current.matches,
        paths,
        counts,
        total_matches,
        total_files,
        last_path: path,
        last_path_stored,
        content_bytes: current.content_bytes,
        content_byte_cut: current.content_byte_cut,
      }
    }
  }
}

///|
fn finish_grep_search(state : Ref[GrepSearchState]) -> GrepSearchResult {
  let current = state.val
  GrepSearchResult::{
    matches: current.matches,
    paths: current.paths,
    counts: current.counts,
    total_matches: current.total_matches,
    total_files: current.total_files,
    content_byte_cut: current.content_byte_cut,
  }
}

///|
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef(
      name=@posoco.ToolName::unchecked("grep"),
      description="Literal file search; set `regex: true` to match a regular expression instead. Content mode returns file headers plus `line|text`; other modes return matching paths or counts. Skips hidden/ignored/binary files. For syntax-shaped code queries (definitions, call sites, AST patterns in source), prefer astgrep.",
      input_schema=Json::object({
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
      owner=@posoco.OwnerId::unchecked("posoco_ext_grep"),
      policy=@posoco.ExecutionPolicy::Parallel,
      provenance=Some("posoco_ext_grep"),
    ),
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
  let content = if m.content_truncated {
    m.content + "…[cut]"
  } else if m.content.length() > GREP_LINE_CHAR_CAP {
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
fn grep_summary(count : Int32, noun : String) -> String {
  if count == 0 {
    "no matches"
  } else {
    "\{count} \{noun}"
  }
}

///|
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
fn grep_result_text(
  mode : GrepOutputMode,
  result : GrepSearchResult,
  max_matches : Int32,
) -> (String, Int32, Bool) {
  let total = if mode is Content {
    result.total_matches
  } else {
    result.total_files
  }
  if total == 0 {
    return ("(no matches)", 0, false)
  }
  match mode {
    Content => {
      let (body, shown, byte_cut) = render_content_body(
        result.matches,
        max_matches,
      )
      let truncated = result.content_byte_cut ||
        byte_cut ||
        shown < result.total_matches
      let mut text = body.trim_end(chars="\n").to_owned()
      if truncated {
        text = "\{text}\n… +\{result.total_matches - shown} matches"
      }
      (text, result.total_matches, truncated)
    }
    FilesWithMatches => {
      let shown = result.paths.length()
      let builder = StringBuilder()
      for path in result.paths {
        builder.write_string(path)
        builder.write_char('\n')
      }
      let mut text = builder.to_string().trim_end(chars="\n").to_owned()
      if shown < result.total_files {
        text = "\{text}\n… +\{result.total_files - shown} files"
      }
      (text, result.total_files, shown < result.total_files)
    }
    Count => {
      let shown = result.paths.length()
      let builder = StringBuilder()
      for i in 0..<shown {
        builder.write_string("\{result.paths[i]}:\{result.counts[i]}")
        builder.write_char('\n')
      }
      let mut text = builder.to_string().trim_end(chars="\n").to_owned()
      if shown < result.total_files {
        text = "\{text}\n… +\{result.total_files - shown} files"
      }
      (text, result.total_files, shown < result.total_files)
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
  let (search_base, path_mapper) = match anchor {
    Some(anchor) => {
      let resolved = anchor.resolve(raw_base)
      (resolved, GrepPathMapper::{ resolved: Some(resolved), raw_base, })
    }
    None => (raw_base, GrepPathMapper::{ resolved: None, raw_base, })
  }
  let result = searcher.search(
    pattern, search_base, file_glob, case_insensitive, use_regex, mode, max_matches,
    path_mapper,
  )
  let (text, count, truncated) = grep_result_text(mode, result, max_matches)
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
