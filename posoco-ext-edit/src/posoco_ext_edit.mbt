///|
// ============================================================================
// posoco-ext-edit — file editing tool (find-and-replace).
//
// File organization:
//   posoco_ext_edit.mbt          — all targets: struct, ctor, shared helpers,
//                                  FsIo trait, SystemPromptContributor,
//                                  execute_edit_impl, list_tools schema
//   posoco_ext_edit_native.mbt   — #cfg(target="native"): NativeFsIo adaptor
//                                  + complete ToolProvider impl (via @fs)
//   posoco_ext_edit_js.mbt       — #cfg(target="js"):      JsFsIo adaptor
//                                  + complete ToolProvider impl (via Bun.file)
//   fallback.mbt                 — #cfg(not(any(native,js))): empty list + error
//
// The struct + FsIo trait + shared business logic live HERE so every target
// sees the same type. Only the IO adaptor + ToolProvider impl differ per
// platform; each platform's adaptor file provides those via #cfg partitions.
// ============================================================================

///|
/// EditTools — file editing tool provider.
/// Performs find-and-replace within a file (single occurrence or all).
///
/// On native, IO via `@fs`. On js (bun), IO via `Bun.file`/`Bun.write`.
/// On wasm/wasm-gc, the tool is not listed and execute raises
/// `RuntimeError::InvocationFailed`.
pub(all) struct EditTools {
  // Stateless — all configuration comes from ToolCall arguments at execute time.
}

///|
/// Canonical constructor. Use this everywhere — the old `EditTools()` positional
/// form is removed to avoid cross-target naming drift.
pub fn EditTools::EditTools() -> EditTools {
  EditTools::{  }
}

// ---------------------------------------------------------------------------
// SystemPromptContributor — identical on every target.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.SystemPromptContributor for EditTools with fn system_prompt(
  _self : EditTools,
) -> String {
  "Use edit for precise changes. If the expected text does not match, re-read the file and fix the cause instead of guessing."
}

// ---------------------------------------------------------------------------
// FsIo trait — the IO adaptor seam. Native and js each provide an impl.
// ---------------------------------------------------------------------------

///|
/// File-system IO boundary for the `edit` tool.
///
/// `@fs` is native-only, so each target supplies its own adaptor. The shared
/// `execute_edit_impl` below talks only to this trait.
priv trait FsIo {
  /// Does the file exist? `false` = missing (recoverable); raise = IO error.
  async fn exists(self : Self, path : String) -> Bool raise @posoco.RuntimeError

  /// Read the entire file as a UTF-8 string. Raise on IO or decode failure.
  async fn read_text(self : Self, path : String) -> String raise @posoco.RuntimeError

  /// Write text content to a file (create or truncate). Raise on IO failure.
  async fn write_text(self : Self, path : String, content : String) -> Unit raise @posoco.RuntimeError
}

// ---------------------------------------------------------------------------
// Shared tool definition + argument extraction + failure formatting.
// ---------------------------------------------------------------------------

///|
/// Shared tool list for the `edit` tool (old_text/new_text/replace_all).
/// Both native and js EditTools expose the same tool definition; only the IO
/// adaptor differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: "edit",
      description: "Edit a file by replacing text. Finds `old_text` and replaces with `new_text`. By default replaces the first occurrence; set `replace_all` to true for all occurrences.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Path to the file to edit"),
          }),
          "old_text": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Text to find in the file"),
          }),
          "new_text": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Replacement text"),
          }),
          "replace_all": Json::object({
            "type": Json::string("boolean"),
            "description": Json::string(
              "Replace all occurrences (default: false)",
            ),
          }),
        }),
        "required": Json::array([
          Json::string("path"),
          Json::string("old_text"),
          Json::string("new_text"),
        ]),
      }),
      metadata: None,
      source: Some("posoco_ext_edit"),
    },
  ]
}

///|
/// Extract `(path, old_text, new_text, replace_all)` from ToolCall arguments.
fn extract_edit_args(
  args : Json,
) -> (String, String, String, Bool) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let p = match obj.get("path") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: 'path' argument must be a string",
          )
        None => raise @posoco.RuntimeError::UnknownTool("edit: missing 'path'")
      }
      let o = match obj.get("old_text") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: 'old_text' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("edit: missing 'old_text'")
      }
      let n = match obj.get("new_text") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: 'new_text' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("edit: missing 'new_text'")
      }
      let ra = match obj.get("replace_all") {
        Some(True) => true
        Some(False) | None => false
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: optional 'replace_all' must be a boolean",
          )
      }
      (p, o, n, ra)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "edit: arguments must be a JSON object",
      )
  }
}

///|
/// Format an `edit` failure RuntimeError with sanitized path.
fn edit_failure(stage : String, path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "edit: \{stage} failed for '\{@devkit.sanitize_path(path)}'",
  )
}

///|
/// Replace the first occurrence of `old` with `new` in a string.
fn replace_first(text : String, old : String, new : String) -> String {
  match text.find(old) {
    None => text
    Some(pos) => {
      let before = text[0:pos].to_owned()
      let after = text[pos + old.length():].to_owned()
      before + new + after
    }
  }
}

///|
/// Apply the replacement logic shared by native + js.
/// `all` toggles first-vs-all semantics.
fn apply_edit(
  content : String,
  old_text : String,
  new_text : String,
  all : Bool,
) -> String {
  if all {
    content.replace_all(old=old_text, new=new_text)
  } else {
    replace_first(content, old_text, new_text)
  }
}

// ---------------------------------------------------------------------------
// execute_edit_impl — single source of truth for the edit tool's logic.
// ---------------------------------------------------------------------------

///|
/// Shared `edit` execute logic. Target-agnostic; only the IO adaptor differs.
async fn execute_edit_impl(
  io : &FsIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let (path, old_text, new_text, all) = extract_edit_args(call.arguments)
  if !io.exists(path) {
    return @posoco.ToolResult::{
      content: "File not found: \{@devkit.sanitize_path(path)}",
      structured: None,
      is_error: true,
    }
  }
  let content = io.read_text(path)
  if !content.contains(old_text) {
    return @posoco.ToolResult::{
      content: "old_text not found in \{@devkit.sanitize_path(path)}",
      structured: None,
      is_error: true,
    }
  }
  let new_content = apply_edit(content, old_text, new_text, all)
  io.write_text(path, new_content)
  @posoco.ToolResult::{
    content: "Edited \{path}",
    structured: None,
    is_error: false,
  }
}
