///|
// ============================================================================
// posoco_ext_write_native.mbt — native target adaptor + ToolProvider impl.
//
// Active on: target="native"
// Provides:  NativeFsIo (via @fs) + complete ToolProvider impl
// ============================================================================

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
// ToolProvider — complete impl (list_tools + execute) for native.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.ToolProvider for WriteTools with fn list_tools(
  _self : WriteTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `write` tool on native. Business logic lives in the shared
/// `execute_write_impl`; this method only supplies the @fs-backed adaptor.
pub impl @posoco.ToolProvider for WriteTools with fn execute(
  _self : WriteTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_write_impl(NativeFsIo::{  }, call)
}
