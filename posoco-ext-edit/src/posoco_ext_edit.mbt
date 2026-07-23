///|
/// posoco_ext_edit.mbt — native target implementation.
///
/// Provides the FsIo adaptor (backed by `@fs`) and the EditTools struct +
/// ToolProvider impl that delegates business logic to `execute_edit_impl`.

// ---------------------------------------------------------------------------
// NativeFsIo — @fs-backed FsIo adaptor.
// ---------------------------------------------------------------------------

///|
priv struct NativeFsIo {}

///|
impl FsIo for NativeFsIo with fn exists(_self, path : String) -> Bool {
  @fs.exists(path) catch {
    _ => raise edit_failure("stat", path)
  }
}

///|
impl FsIo for NativeFsIo with fn read_text(_self, path : String) -> String {
  let data = @fs.read_file(path) catch { _ => raise edit_failure("read", path) }
  data.text() catch {
    _ => raise edit_failure("decode", path)
  }
}

///|
impl FsIo for NativeFsIo with fn write_text(
  _self,
  path : String,
  content : String,
) -> Unit {
  @fs.write_file(path, content) catch {
    _ => raise edit_failure("write", path)
  }
}

// ---------------------------------------------------------------------------
// EditTools — native struct + ToolProvider impl.
// ---------------------------------------------------------------------------

///|
/// EditTools — file editing tool provider.
/// Performs find-and-replace within a file (single occurrence or all).
pub(all) struct EditTools {}

///|
pub fn EditTools::new() -> EditTools {
  EditTools::{  }
}

///|
pub impl @posoco.ToolProvider for EditTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  shared_list_tools()
}

///|
/// Execute the `edit` tool on native. Business logic lives in the shared
/// `execute_edit_impl`; this method only supplies the @fs-backed adaptor.
pub impl @posoco.ToolProvider for EditTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  execute_edit_impl(NativeFsIo::{  }, call)
}
