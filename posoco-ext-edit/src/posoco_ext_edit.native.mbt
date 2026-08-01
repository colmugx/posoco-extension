///|
// ============================================================================
// posoco_ext_edit_native.mbt — native target adaptor + ToolProvider impl.
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
// ToolProvider — complete impl (list_tools + execute) for native.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.ToolProvider for EditTools with fn list_tools(
  _self : EditTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `edit` tool on native. Business logic lives in the shared
/// `execute_edit_impl`; this method only supplies the @fs-backed adaptor.
pub impl @posoco.ToolProvider for EditTools with fn execute(
  _self : EditTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_edit_impl(NativeFsIo::{  }, call)
}
