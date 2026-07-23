///|
/// posoco_ext_write.mbt — native target implementation.
///
/// Provides the FsIo adaptor (backed by `@fs`) and the WriteTools struct +
/// ToolProvider impl that delegates business logic to `execute_write_impl`.

// ---------------------------------------------------------------------------
// NativeFsIo — @fs-backed FsIo adaptor.
// ---------------------------------------------------------------------------

///|
priv struct NativeFsIo {}

///|
/// `@fs.write_file` creates or truncates. Raise on IO failure.
impl FsIo for NativeFsIo with fn write_text(
  _self,
  path : String,
  content : String,
) -> Unit {
  @fs.write_file(path, content) catch {
    _ => raise write_failure(path)
  }
}

// ---------------------------------------------------------------------------
// WriteTools — native struct + ToolProvider impl.
// ---------------------------------------------------------------------------

///|
/// WriteTools — file writing tool provider.
pub(all) struct WriteTools {}

///|
pub fn WriteTools::new() -> WriteTools {
  WriteTools::{  }
}

///|
pub impl @posoco.ToolProvider for WriteTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  shared_list_tools()
}

///|
/// Execute the `write` tool on native. Business logic lives in the shared
/// `execute_write_impl`; this method only supplies the @fs-backed adaptor.
pub impl @posoco.ToolProvider for WriteTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  execute_write_impl(NativeFsIo::{  }, call)
}
