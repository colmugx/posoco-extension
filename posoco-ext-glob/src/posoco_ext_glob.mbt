///|
// ============================================================================
// posoco-ext-glob — file pattern matching tool.
//
// File organization:
//   posoco_ext_glob.mbt          — all targets: struct, ctor, shared helpers,
//                                  SystemPromptContributor, GlobScanner trait,
//                                  shared_list_tools, extract_glob_args,
//                                  execute_glob_impl
//   posoco_ext_glob_native.mbt   — #cfg(target="native"): @fs.walk scanner +
//                                  glob-matching engine + ToolProvider impl
//   posoco_ext_glob_js.mbt       — #cfg(target="js"):      Bun.Glob scanner +
//                                  ToolProvider impl
//   fallback.mbt                 — #cfg(not(any(native,js))): empty list + error
//
// The struct + trait + shared execute logic live HERE so every target sees the
// same type. Only the scanner adaptor differs per platform; each platform's
// adaptor file provides its own scanner struct + a complete ToolProvider impl.
// ============================================================================

///|
/// GlobTools — file pattern matching tool provider.
///
/// Walks a directory tree and returns paths matching a glob-like pattern.
/// Supports `*` (any chars in one segment) and `**` (recursive).
/// On native, scanning uses `@fs.walk` + a MoonBit glob-matching engine;
/// on js (bun), scanning delegates to `Bun.Glob`. On wasm/wasm-gc, the tool
/// is not listed and execute raises `RuntimeError::InvocationFailed`.
pub(all) struct GlobTools {
  // Stateless — all configuration comes from ToolCall arguments at execute time.
}

///|
/// Canonical constructor. Use this everywhere — the old `GlobTools::GlobTools()`
/// positional form is removed to avoid cross-target naming drift.
pub fn GlobTools::GlobTools() -> GlobTools {
  GlobTools::{  }
}

// ---------------------------------------------------------------------------
// SystemPromptContributor — identical on every target.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.SystemPromptContributor for GlobTools with fn system_prompt(
  _self : GlobTools,
) -> String {
  "Use glob to discover relevant paths before assuming the workspace layout."
}

// ---------------------------------------------------------------------------
// GlobScanner trait — the search adaptor seam. Native and js each provide one.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Shared tool definition + argument extraction.
// ---------------------------------------------------------------------------

///|
/// Shared tool definition for the `glob` tool.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: "glob",
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
      metadata: None,
      source: Some("posoco_ext_glob"),
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

// ---------------------------------------------------------------------------
// execute_glob_impl — single source of truth for the glob tool's logic.
// ---------------------------------------------------------------------------

///|
/// Shared `glob` execute logic. Target-agnostic; only the scanner differs.
async fn execute_glob_impl(
  scanner : &GlobScanner,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let (pattern, base) = extract_glob_args(call.arguments)
  let matches = scanner.scan(pattern, base)
  let builder = StringBuilder::new()
  for m in matches {
    builder.write_string(m)
    builder.write_char('\n')
  }
  @posoco.ToolResult::{
    content: "Found \{matches.length()} files:\n\{builder.to_string()}",
    structured: None,
    is_error: false,
  }
}
