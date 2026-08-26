///|
priv struct NativeFsIo {}

///|
/// Process-local counter for sibling temp-file names (workspace-ext pattern).
let edit_tmp_counter : Ref[Int] = { val: 0 }

///|
impl FsIo for NativeFsIo with fn exists(_self, path : String) -> Bool {
  @fs.exists(path) catch {
    _ => raise edit_failure("stat", path)
  }
}

///|
/// Stamp for freshness tracking: `mtime` plus size from an open read handle.
impl FsIo for NativeFsIo with fn stat(_self, path : String) -> @devkit.FileStamp {
  let (mtime_s, mtime_ns) = @fs.mtime(path) catch {
    _ => raise edit_failure("stat", path)
  }
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly) catch {
    _ => raise edit_failure("stat", path)
  }
  let size = file.size() catch {
    _ => {
      file.close()
      raise edit_failure("stat", path)
    }
  }
  file.close()
  { mtime_s, mtime_ns, size }
}

///|
impl FsIo for NativeFsIo with fn read_text(_self, path : String) -> String {
  let data = @fs.read_file(path) catch { _ => raise edit_failure("read", path) }
  data.text() catch {
    _ => raise edit_failure("decode", path)
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
    _ => raise edit_failure("write", path)
  }
  @fs.rename(tmp, path, replace=true) catch {
    _ => {
      @fs.remove(tmp) catch {
        _ => ()
      }
      raise edit_failure("write", path)
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
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_edit_impl(NativeFsIo::{  }, self.freshness, self.anchor, call)
}
