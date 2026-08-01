///|
// ============================================================================
// posoco-ext-write — file writing tool.
//
// File organization:
//   posoco_ext_write.mbt          — all targets: struct, ctor, shared helpers,
//                                   FsIo trait, SystemPromptContributor,
//                                   execute_write_impl, list_tools schema
//   posoco_ext_write_native.mbt   — #cfg(target="native"): NativeFsIo adaptor
//                                   + complete ToolProvider impl (via @fs)
//   posoco_ext_write_js.mbt       — #cfg(target="js"):      JsFsIo adaptor
//                                   + complete ToolProvider impl (via Bun.write)
//   fallback.mbt                  — #cfg(not(any(native,js))): empty list + error
//
// The struct + FsIo trait + shared business logic live HERE so every target
// sees the same type. Only the IO adaptor + ToolProvider impl differ per
// platform; each platform's adaptor file provides those via #cfg partitions.
// ============================================================================

///|
/// WriteTools — file writing tool provider.
///
/// On native, writes via `@fs.write_file`. On js (bun), writes via `Bun.write`.
/// On wasm/wasm-gc, the tool is not listed and execute raises
/// `RuntimeError::InvocationFailed`.
pub(all) struct WriteTools {
  // Stateless — all configuration comes from ToolCall arguments at execute time.
}

///|
/// Canonical constructor. Use this everywhere — the old `WriteTools()` positional
/// form is removed to avoid cross-target naming drift.
pub fn WriteTools::WriteTools() -> WriteTools {
  WriteTools::{  }
}

// ---------------------------------------------------------------------------
// SystemPromptContributor — identical on every target.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.SystemPromptContributor for WriteTools with fn system_prompt(
  _self : WriteTools,
) -> String {
  "Use write for new files or intentional complete replacement; do not use it to hide a failed targeted edit."
}

// ---------------------------------------------------------------------------
// FsIo trait — the IO adaptor seam. Native and js each provide an impl.
// ---------------------------------------------------------------------------

///|
/// File-system IO boundary for the `write` tool.
///
/// `@fs` is native-only, so each target supplies its own adaptor. The shared
/// `execute_write_impl` below talks only to this trait.
priv trait FsIo {
  /// Write text content to a file (create or truncate). Raise on IO failure.
  async fn write_text(self : Self, path : String, content : String) -> Unit raise @posoco.RuntimeError
}

// ---------------------------------------------------------------------------
// Shared tool definition + argument extraction + failure formatting.
// ---------------------------------------------------------------------------

///|
/// Shared tool list for the `write` tool. Both native and js WriteTools expose
/// the same tool definition; only the IO adaptor differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("write"),
      description: "Write text content to a file. Creates the file if it does not exist; truncates if it does.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Path to the file to write"),
          }),
          "content": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Text content to write"),
          }),
        }),
        "required": Json::array([Json::string("path"), Json::string("content")]),
      }),
      owner: @posoco.OwnerId::unchecked("posoco_ext_write"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_write"),
    },
  ]
}

///|
/// Extract `(path, content)` from ToolCall arguments.
fn extract_path_content(
  args : Json,
) -> (String, String) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let p = match obj.get("path") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "write: 'path' argument must be a string",
          )
        None => raise @posoco.RuntimeError::UnknownTool("write: missing 'path'")
      }
      let c = match obj.get("content") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "write: 'content' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("write: missing 'content'")
      }
      (p, c)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "write: arguments must be a JSON object",
      )
  }
}

///|
/// Format a `write` failure RuntimeError with sanitized path.
fn write_failure(path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "write: write failed for '\{@devkit.sanitize_path(path)}'",
  )
}

// ---------------------------------------------------------------------------
// execute_write_impl — single source of truth for the write tool's logic.
// ---------------------------------------------------------------------------

///|
/// Shared `write` execute logic. Target-agnostic; only the IO adaptor differs.
async fn execute_write_impl(
  io : &FsIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (path, content) = extract_path_content(call.arguments)
  io.write_text(path, content)
  @posoco.ToolOutcome::Success(
    content="Wrote \{content.length()} bytes to \{path}",
    structured=None,
  )
}
