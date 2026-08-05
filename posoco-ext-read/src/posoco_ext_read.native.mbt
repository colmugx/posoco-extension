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

///|
pub impl @posoco.ToolProvider for ReadTools with fn list_tools(
  _self : ReadTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `read` tool on native. Business logic lives in the shared
/// `execute_read_impl`; this method only supplies the @fs-backed adaptor.
pub impl @posoco.ToolProvider for ReadTools with fn execute(
  _self : ReadTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_read_impl(NativeFsIo::{  }, call)
}
