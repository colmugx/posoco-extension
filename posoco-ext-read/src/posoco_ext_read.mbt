///|
/// posoco_ext_read.mbt — native target implementation.
///
/// Provides the FsIo adaptor (backed by `@fs`) and the ReadTools struct +
/// ToolProvider impl that delegates business logic to `execute_read_impl`.

// ---------------------------------------------------------------------------
// NativeFsIo — @fs-backed FsIo adaptor.
// ---------------------------------------------------------------------------

///|
priv struct NativeFsIo {}

///|
/// `@fs.exists` returns false for a missing file; a raise means a real IO
/// error (permission, broken symlink), which surfaces as a RuntimeError.
impl FsIo for NativeFsIo with fn exists(_self, path : String) -> Bool {
  @fs.exists(path) catch {
    _ => raise read_failure("stat", path)
  }
}

///|
/// `@fs.read_file` returns `&@io.Data`; `.text()` decodes to UTF-8. Both
/// failure modes (IO read, UTF-8 decode) propagate as RuntimeError.
impl FsIo for NativeFsIo with fn read_text(_self, path : String) -> String {
  let data = @fs.read_file(path) catch { _ => raise read_failure("read", path) }
  data.text() catch {
    _ => raise read_failure("decode", path)
  }
}

// ---------------------------------------------------------------------------
// ReadTools — native struct + ToolProvider impl.
// ---------------------------------------------------------------------------

///|
/// ReadTools — file reading tool provider.
pub(all) struct ReadTools {}

///|
pub fn ReadTools::new() -> ReadTools {
  ReadTools::{  }
}

///|
pub impl @posoco.ToolProvider for ReadTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  shared_list_tools()
}

///|
/// Execute the `read` tool on native. Business logic lives in the shared
/// `execute_read_impl`; this method only supplies the @fs-backed adaptor.
pub impl @posoco.ToolProvider for ReadTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  execute_read_impl(NativeFsIo::{  }, call)
}
