///|
priv struct NativeFsIo {}

///|
/// Process-local counter for sibling temp-file names (workspace-ext pattern).
let write_tmp_counter : Ref[Int] = { val: 0, }

///|
/// `@fs.exists` returns false for a missing file; a raise means a real IO
/// error (permission, broken symlink), which surfaces as a RuntimeError.
impl FsIo for NativeFsIo with fn exists(_self, path : String) -> Bool {
  @fs.exists(path) catch {
    error => raise write_failure("stat", path, error.to_string())
  }
}

///|
/// Stamp for freshness tracking: `mtime` plus size from an open read handle
/// (`@fs` exposes size only on `File`, not as a path-based stat).
impl FsIo for NativeFsIo with fn stat(_self, path : String) -> @devkit.FileStamp {
  let (mtime_s, mtime_ns) = @fs.mtime(path) catch {
    error => raise write_failure("stat", path, error.to_string())
  }
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly) catch {
    error => raise write_failure("stat", path, error.to_string())
  }
  let size = file.size() catch {
    error => {
      file.close()
      raise write_failure("stat", path, error.to_string())
    }
  }
  file.close()
  { mtime_s, mtime_ns, size, }
}

///|
/// Atomic write: best-effort recursive parent mkdir, then a sibling temp
/// file (0o644) renamed over the target. A failed rename removes the temp
/// file so no partial state is left behind.
impl FsIo for NativeFsIo with fn write_atomic(
  _self,
  path : String,
  content : String,
) -> Unit {
  let parent = parent_dir(path)
  if parent != "." && parent != "/" {
    @fs.mkdir(parent, recursive=true) catch {
      _ => () // a real failure surfaces at write/rename below
    }
  }
  write_tmp_counter.val += 1
  let tmp = "\{path}.tmp-\{write_tmp_counter.val}"
  @fs.write_file(tmp, content, create_mode=CreateOrTruncate, permission=0o644) catch {
    error => raise write_failure("write", path, error.to_string())
  }
  @fs.rename(tmp, path, replace=true) catch {
    error => {
      @fs.remove(tmp) catch {
        _ => ()
      }
      raise write_failure("write", path, error.to_string())
    }
  }
}

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
  self : WriteTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let call : @posoco.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }
  execute_write_impl(NativeFsIo::{ }, self.freshness, self.anchor, call)
}
