///|
// ============================================================================
// posoco-ext-grep — content search tool.
//
// File organization:
//   posoco_ext_grep.mbt          — all targets: struct, ctor, shared helpers,
//                                  SystemPromptContributor, GrepSearcher trait,
//                                  shared_list_tools, extract_grep_args,
//                                  execute_grep_impl
//   posoco_ext_grep.native.mbt   — native: @fs.walk searcher + ToolProvider impl
//   posoco_ext_grep.js.mbt       — js: rg-backed searcher + ToolProvider impl
//   fallback.mbt                 — #cfg(not(any(native,js))): empty list + error
//
// The struct + trait + shared execute logic live HERE so every target sees the
// same type. Only the searcher adaptor differs per platform; each platform's
// adaptor file provides its own searcher struct + a complete ToolProvider impl.
// ============================================================================

///|
/// GrepTools — content search tool provider.
///
/// Searches for a pattern in files under a directory and returns matching lines.
/// On native, scanning uses `@fs.walk` + per-line `contains`;
/// on js (bun), delegates to `rg` (ripgrep). On wasm/wasm-gc, the tool is not
/// listed and execute raises `RuntimeError::InvocationFailed`.
pub(all) struct GrepTools {
  // Stateless — all configuration comes from ToolCall arguments at execute time.
}

///|
/// Canonical constructor.
pub fn GrepTools::GrepTools() -> GrepTools {
  GrepTools::{  }
}

// ---------------------------------------------------------------------------
// SystemPromptContributor — identical on every target.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.SystemPromptContributor for GrepTools with fn system_prompt(
  _self : GrepTools,
) -> String {
  "Use grep to locate definitions and call sites before making cross-file changes."
}

// ---------------------------------------------------------------------------
// GrepSearcher trait — the search adaptor seam. Native and js each provide one.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Shared tool definition + argument extraction + result formatting.
// ---------------------------------------------------------------------------

///|
/// Shared tool definition for the `grep` tool.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: "grep",
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
      metadata: None,
      source: Some("posoco_ext_grep"),
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

// ---------------------------------------------------------------------------
// execute_grep_impl — single source of truth for the grep tool's logic.
// ---------------------------------------------------------------------------

///|
/// Shared `grep` execute logic. Target-agnostic; only the searcher differs.
async fn execute_grep_impl(
  searcher : &GrepSearcher,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let (pattern, base, file_glob) = extract_grep_args(call.arguments)
  let results = searcher.search(pattern, base, file_glob)
  @posoco.ToolResult::{
    content: grep_result_text(results, pattern),
    structured: None,
    is_error: false,
  }
}
