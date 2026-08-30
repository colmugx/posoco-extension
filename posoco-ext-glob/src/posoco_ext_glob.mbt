///|
/// GlobTools — file pattern matching tool provider.
///
/// Scans a directory tree and returns file paths (never directories)
/// matching a glob-like pattern, sorted by modification time (newest
/// first). Supports `*` (any chars in one segment) and `**` (recursive).
/// Hidden entries and `ignores` directories are pruned. On native, scanning
/// uses `@fs.walk` + a MoonBit glob-matching engine; on js (bun), scanning
/// delegates to `Bun.Glob`. On wasm/wasm-gc, the tool is not listed and
/// execute raises `RuntimeError::InvocationFailed`.
pub(all) struct GlobTools {
  // Resolves the scan base against the workspace root; None keeps legacy
  // behavior (the base lands on the process working directory).
  anchor : @devkit.WorkspaceAnchor?
  // Directory/file names pruned during traversal; defaults to
  // @devkit.default_ignore_patterns(). Hidden entries are always skipped.
  ignores : Array[String]
}

///|
/// Canonical constructor. Use this everywhere.
pub fn GlobTools::GlobTools(
  anchor? : @devkit.WorkspaceAnchor? = None,
  ignores? : Array[String] = @devkit.default_ignore_patterns(),
) -> GlobTools {
  GlobTools::{ anchor, ignores, }
}

///|
/// Default cap on returned paths when the call omits `limit`.
const GLOB_DEFAULT_LIMIT = 100

///|
/// High-level glob search boundary.
///
/// Native implements this with `@fs.walk` + a MoonBit glob-matching engine;
/// js delegates matching to Bun.Glob. Both return file paths only, sorted
/// newest-first; the shared `execute_glob_impl` applies the limit and
/// formats the result identically regardless of engine.
priv trait GlobScanner {
  /// Scan `base` for file paths matching `pattern`, newest first. Raise on
  /// IO failure of the base itself; per-entry failures are skipped.
  async fn scan(self : Self, pattern : String, base : String) -> Array[String] raise @posoco.RuntimeError
}

///|
/// Shared tool definition for the `glob` tool.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("glob"),
      description: "Find files matching a glob pattern. Supports * (single segment wildcard) and ** (recursive). Example: '**/*.mbt' finds all .mbt files recursively. Returns file paths only (never directories), sorted by modification time (newest first). Hidden files and common ignore directories (.git, node_modules, _build, ...) are skipped. Optional 'limit' caps results (default 100); truncated results end with a footer reporting the remainder.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "pattern": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Glob pattern (e.g. '**/*.mbt', 'src/*.mbt')",
            ),
          }),
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Base directory to search (default: '.')",
            ),
          }),
          "limit": Json::object({
            "type": Json::string("integer"),
            "description": Json::string(
              "Maximum number of paths to return (default 100)",
            ),
          }),
        }),
        "required": Json::array([Json::string("pattern")]),
      }),
      owner: @posoco.OwnerId::unchecked("posoco_ext_glob"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_glob"),
    },
  ]
}

///|
/// Extract `(pattern, base, limit)` from ToolCall arguments. `base`
/// defaults to "."; `limit` defaults to 100 and must be positive.
fn extract_glob_args(
  args : Json,
) -> (String, String, Int) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let p = match obj.get("pattern") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "glob: 'pattern' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("glob: missing 'pattern'")
      }
      let b = match obj.get("path") {
        Some(String(s)) => s
        None => "."
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "glob: optional 'path' must be a string",
          )
      }
      let limit = match obj.get("limit") {
        None | Some(Null) => GLOB_DEFAULT_LIMIT
        Some(Number(n, ..)) => {
          let v = n.to_int()
          if v <= 0 {
            raise @posoco.RuntimeError::UnknownTool(
              "glob: 'limit' must be greater than zero",
            )
          }
          v
        }
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "glob: optional 'limit' must be an integer",
          )
      }
      (p, b, limit)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "glob: arguments must be a JSON object",
      )
  }
}

///|
/// One-line UI summary for the structured payload: "N files", or "no files"
/// when the scan found nothing.
fn glob_summary(count : Int) -> String {
  if count == 0 {
    "no files"
  } else {
    "\{count} files"
  }
}

///|
/// Structured payload for observers/UIs; never sent to the model. Carries
/// the reserved `summary` field plus the total file count and truncation
/// flag.
fn glob_structured(count : Int, truncated : Bool) -> Json {
  Json::object(
    Map::from_array([
      ("summary", Json::string(glob_summary(count))),
      ("count", Json::number(count.to_double())),
      ("truncated", Json::boolean(truncated)),
    ]),
  )
}

///|
/// Shared `glob` execute logic. Target-agnostic; only the scanner differs.
///
/// When anchored, the scan runs in the resolved directory and results are
/// re-anchored relative to the scan base (the js scanner's native format),
/// so the workspace root never leaks into model-visible output.
async fn execute_glob_impl(
  scanner : &GlobScanner,
  anchor : @devkit.WorkspaceAnchor?,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (pattern, raw_base, limit) = extract_glob_args(call.arguments)
  let matches = match anchor {
    Some(anchor) => {
      let resolved = anchor.resolve(raw_base)
      let found = scanner.scan(pattern, resolved) catch {
        _ =>
          raise @posoco.RuntimeError::InvocationFailed(
            "glob: scan failed for '\{@devkit.sanitize_path(raw_base)}'",
          )
      }
      let prefix = if resolved == "/" { "/" } else { "\{resolved}/" }
      [
        for m in found => glob_strip_prefix(@devkit.strip_dot_prefix(m), prefix)
      ]
    }
    None =>
      [
        for m in scanner.scan(pattern, raw_base) => @devkit.strip_dot_prefix(m)
      ]
  }
  let total = matches.length()
  let shown = if total < limit { total } else { limit }
  let builder = StringBuilder()
  for i in 0..<shown {
    builder.write_string(matches[i])
    builder.write_char('\n')
  }
  let mut content = "Found \{total} files:\n\{builder.to_string()}"
  if shown < total {
    content = "\{content}… \{total - shown} more files; narrow the pattern or raise limit\n"
  }
  @posoco.ToolOutcome::Success(
    content~,
    structured=Some(glob_structured(total, shown < total)),
  )
}

///|
/// Drop `prefix` from `s` when present; on an impossible slice boundary the
/// string passes through unchanged.
fn glob_strip_prefix(s : String, prefix : String) -> String {
  if !s.has_prefix(prefix) {
    return s
  }
  s[prefix.length():].to_owned()
}
