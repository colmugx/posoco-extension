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
/// Canonical constructor. Use this everywhere.
pub fn EditTools::EditTools() -> EditTools {
  EditTools::{  }
}

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

///|
/// Shared tool list for the `edit` tool (old_text/new_text/replace_all).
/// Both native and js EditTools expose the same tool definition; only the IO
/// adaptor differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("edit"),
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
      owner: @posoco.OwnerId::unchecked("posoco_ext_edit"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_edit"),
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

///|
/// Shared `edit` execute logic. Target-agnostic; only the IO adaptor differs.
async fn execute_edit_impl(
  io : &FsIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (path, old_text, new_text, all) = extract_edit_args(call.arguments)
  if !io.exists(path) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="File not found: \{@devkit.sanitize_path(path)}",
      structured=None,
    )
  }
  let content = io.read_text(path)
  if !content.contains(old_text) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="old_text not found in \{@devkit.sanitize_path(path)}",
      structured=None,
    )
  }
  let new_content = apply_edit(content, old_text, new_text, all)
  io.write_text(path, new_content)
  @posoco.ToolOutcome::Success(content="Edited \{path}", structured=None)
}
