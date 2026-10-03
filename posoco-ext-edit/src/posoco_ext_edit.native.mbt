///|
priv struct NativeFsIo {}

///|
/// Process-local counter for sibling temp-file names (workspace-ext pattern).
let edit_tmp_counter : Ref[Int] = { val: 0, }

///|
impl FsIo for NativeFsIo with fn exists(_self, path : String) -> Bool {
  @fs.exists(path) catch {
    error => raise edit_failure("stat", path, error.to_string())
  }
}

///|
/// Stamp for freshness tracking: `mtime` plus size from an open read handle.
impl FsIo for NativeFsIo with fn stat(_self, path : String) -> @devkit.FileStamp {
  let (mtime_s, mtime_ns) = @fs.mtime(path) catch {
    error => raise edit_failure("stat", path, error.to_string())
  }
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly) catch {
    error => raise edit_failure("stat", path, error.to_string())
  }
  let size = file.size() catch {
    error => {
      file.close()
      raise edit_failure("stat", path, error.to_string())
    }
  }
  file.close()
  { mtime_s, mtime_ns, size, }
}

///|
impl FsIo for NativeFsIo with fn read_text(_self, path : String) -> String {
  let data = @fs.read_file(path) catch {
    error => raise edit_failure("read", path, error.to_string())
  }
  data.text() catch {
    _ => raise edit_failure("decode", path, "invalid UTF-8")
  }
}

///|
/// Atomic write: sibling temp file renamed over the target; a failed rename
/// removes the temp file so no partial state is left behind.
impl FsIo for NativeFsIo with fn write_atomic(
  _self,
  path : String,
  content : String,
) -> Unit {
  edit_tmp_counter.val += 1
  let tmp = "\{path}.tmp-\{edit_tmp_counter.val}"
  @fs.write_file(tmp, content, create_mode=CreateOrTruncate, permission=0o644) catch {
    error => raise edit_failure("write", path, error.to_string())
  }
  @fs.rename(tmp, path, replace=true) catch {
    error => {
      @fs.remove(tmp) catch {
        _ => ()
      }
      raise edit_failure("write", path, error.to_string())
    }
  }
}

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
  self : EditTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let call : @posoco.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }
  execute_edit_impl(NativeFsIo::{ }, self.freshness, self.anchor, call)
}
