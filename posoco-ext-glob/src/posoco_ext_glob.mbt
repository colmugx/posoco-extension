///|
/// GlobTools — file pattern matching tool provider.
///
/// Walks a directory tree and returns paths matching a glob-like pattern.
/// Supports `*` (any chars in one segment) and `**` (recursive).
/// On native, scanning uses `@fs.walk` + a MoonBit glob-matching engine;
/// on js (bun), scanning delegates to `Bun.Glob`. On wasm/wasm-gc, the tool
/// is not listed and execute raises `RuntimeError::InvocationFailed`.
pub(all) struct GlobTools {
  // Resolves the scan base against the workspace root; None keeps legacy
  // behavior (the base lands on the process working directory).
  anchor : @devkit.WorkspaceAnchor?
}

///|
/// Canonical constructor. Use this everywhere.
pub fn GlobTools::GlobTools(
  anchor? : @devkit.WorkspaceAnchor? = None,
) -> GlobTools {
  GlobTools::{ anchor, }
}

///|
/// High-level glob search boundary.
///
/// Native implements this with `@fs.walk` + a MoonBit glob-matching engine;
/// js delegates to `Bun.Glob.scan`. The shared `execute_glob_impl` formats
/// the result the same way regardless of engine.
priv trait GlobScanner {
  /// Scan `base` for paths matching `pattern`. Raise on IO failure.
  async fn scan(self : Self, pattern : String, base : String) -> Array[String] raise @posoco.RuntimeError
}

///|
/// Shared tool definition for the `glob` tool.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("glob"),
      description: "Find files matching a glob pattern. Supports * (single segment wildcard) and ** (recursive). Example: '**/*.mbt' finds all .mbt files recursively.",
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
/// Extract `(pattern, base)` from ToolCall arguments. `base` defaults to ".".
fn extract_glob_args(
  args : Json,
) -> (String, String) raise @posoco.RuntimeError {
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
      (p, b)
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
/// Structured payload for observers/UIs; never sent to the model. Carries the
/// reserved `summary` field plus the file count.
fn glob_structured(count : Int) -> Json {
  Json::object(
    Map::from_array([
      ("summary", Json::string(glob_summary(count))),
      ("count", Json::number(count.to_double())),
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
  let (pattern, raw_base) = extract_glob_args(call.arguments)
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
        for m in found => glob_strip_prefix(m, prefix)
      ]
    }
    None => scanner.scan(pattern, raw_base)
  }
  let builder = StringBuilder::new()
  for m in matches {
    builder.write_string(m)
    builder.write_char('\n')
  }
  @posoco.ToolOutcome::Success(
    content="Found \{matches.length()} files:\n\{builder.to_string()}",
    structured=Some(glob_structured(matches.length())),
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
