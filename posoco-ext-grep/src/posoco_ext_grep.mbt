///|
/// GrepTools — content search tool provider.
///
/// Searches for a pattern in files under a directory and returns matching lines.
/// On native, scanning uses `@fs.walk` + per-line `contains`;
/// on js (bun), delegates to `rg` (ripgrep). On wasm/wasm-gc, the tool is not
/// listed and execute raises `RuntimeError::InvocationFailed`.
pub(all) struct GrepTools {
  // Resolves the search base against the workspace root; None keeps legacy
  // behavior (the base lands on the process working directory).
  anchor : @devkit.WorkspaceAnchor?
}

///|
/// Canonical constructor.
pub fn GrepTools::GrepTools(
  anchor? : @devkit.WorkspaceAnchor? = None,
) -> GrepTools {
  GrepTools::{ anchor, }
}

///|
/// High-level content-search boundary.
///
/// Native walks the tree in-process (`@fs.walk` + per-line `contains`);
/// js shells out to `rg`. Both return `path:line:content` entries, so the
/// shared `execute_grep_impl` formats results identically.
priv trait GrepSearcher {
  /// Search for `pattern` under `base`, filtered by optional `file_glob`.
  /// Returns `path:line:content` strings. Raise on IO failure.
  async fn search(
    self : Self,
    pattern : String,
    base : String,
    file_glob : String,
  ) -> Array[String] raise @posoco.RuntimeError
}

///|
/// Shared tool definition for the `grep` tool.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("grep"),
      description: "Search for a text pattern in files. Returns matching lines with file paths and line numbers. Searches recursively under the given path.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "pattern": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Text pattern to search for"),
          }),
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Directory to search in (default: '.')"),
          }),
          "glob": Json::object({
            "type": Json::string("string"),
            "description": Json::string("File pattern filter (e.g. '*.mbt')"),
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
/// Extract `(pattern, base, file_glob)` from ToolCall arguments.
/// `base` defaults to "."; `file_glob` defaults to "".
fn extract_grep_args(
  args : Json,
) -> (String, String, String) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let p = match obj.get("pattern") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: 'pattern' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("grep: missing 'pattern'")
      }
      let b = match obj.get("path") {
        Some(String(s)) => s
        None => "."
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: optional 'path' must be a string",
          )
      }
      let g = match obj.get("glob") {
        Some(String(s)) => s
        None => ""
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: optional 'glob' must be a string",
          )
      }
      (p, b, g)
    }
    _ => raise @posoco.RuntimeError::UnknownTool("grep: invalid arguments")
  }
}

///|
/// Build the result text from a list of "file:line:line-content" matches.
fn grep_result_text(results : Array[String], pattern : String) -> String {
  if results.length() == 0 {
    return "No matches found for: " + pattern
  }
  let builder = StringBuilder::new()
  builder.write_string("Found ")
  builder.write_string(results.length().to_string())
  builder.write_string(" matches:\n")
  for r in results {
    builder.write_string(r)
    builder.write_char('\n')
  }
  builder.to_string()
}

///|
/// One-line UI summary for the structured payload: "1 match", "N matches",
/// or "no matches" when the search found nothing.
fn grep_summary(count : Int) -> String {
  if count == 0 {
    "no matches"
  } else if count == 1 {
    "1 match"
  } else {
    "\{count} matches"
  }
}

///|
/// Structured payload for observers/UIs; never sent to the model. Carries the
/// reserved `summary` field plus the match count.
fn grep_structured(count : Int) -> Json {
  Json::object(
    Map::from_array([
      ("summary", Json::string(grep_summary(count))),
      ("count", Json::number(count.to_double())),
    ]),
  )
}

///|
/// Shared `grep` execute logic. Target-agnostic; only the searcher differs.
///
/// When anchored, the search runs in the resolved directory and result paths
/// are re-anchored to the argument spelling, so the workspace root never
/// leaks into model-visible output.
async fn execute_grep_impl(
  searcher : &GrepSearcher,
  anchor : @devkit.WorkspaceAnchor?,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (pattern, raw_base, file_glob) = extract_grep_args(call.arguments)
  let results = match anchor {
    Some(anchor) => {
      let resolved = anchor.resolve(raw_base)
      let found = searcher.search(pattern, resolved, file_glob) catch {
        _ =>
          raise @posoco.RuntimeError::InvocationFailed(
            "grep: search failed for '\{@devkit.sanitize_path(raw_base)}'",
          )
      }
      [
        for r in found => grep_rebase(r, resolved, raw_base)
      ]
    }
    None => searcher.search(pattern, raw_base, file_glob)
  }
  @posoco.ToolOutcome::Success(
    content=grep_result_text(results, pattern),
    structured=Some(grep_structured(results.length())),
  )
}

///|
/// Rewrite a `path:line:content` result produced under `resolved` back to the
/// `raw_base` spelling (no prefix when the base was the default "."). Results
/// whose path does not carry the resolved prefix pass through unchanged.
fn grep_rebase(result : String, resolved : String, raw_base : String) -> String {
  let prefix = if resolved == "/" { "/" } else { "\{resolved}/" }
  if !result.has_prefix(prefix) {
    return result
  }
  let rest = result[prefix.length():].to_owned()
  if raw_base == "." || raw_base == "" {
    rest
  } else {
    "\{raw_base}/\{rest}"
  }
}
