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
/// Stamp for freshness tracking: `mtime` plus size taken from an open read
/// handle (`@fs` exposes size only on `File`, not as a path-based stat).
impl FsIo for NativeFsIo with fn stat(_self, path : String) -> @devkit.FileStamp {
  // Classify directories before opening: a directory read must surface with
  // the same `read` stage as the whole-file reader it replaces, not `stat`.
  let kind = @fs.kind(path) catch { _ => raise read_failure("stat", path) }
  if kind is @fs.FileKind::Directory {
    raise read_failure("read", path)
  }
  let (mtime_s, mtime_ns) = @fs.mtime(path) catch {
    _ => raise read_failure("stat", path)
  }
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly) catch {
    _ => raise read_failure("stat", path)
  }
  let size = file.size() catch {
    _ => {
      file.close()
      raise read_failure("stat", path)
    }
  }
  file.close()
  { mtime_s, mtime_ns, size }
}

///|
/// Stream the file line by line: lines before `skip` are counted but never
/// materialized, collection stops after `take` lines, and the scan continues
/// to EOF so `total_lines` is exact. Invalid UTF-8 surfaces as a distinct
/// `decode` stage, matching the whole-file reader it replaces.
async fn native_read_lines(
  path : String,
  skip : Int,
  take : Int,
) -> LinePage raise @posoco.RuntimeError {
  let file = @fs.open(path, mode=@fs.Mode::ReadOnly) catch {
    _ => raise read_failure("read", path)
  }
  let total_bytes = file.size() catch {
    _ => {
      file.close()
      raise read_failure("read", path)
    }
  }
  let lines : Array[String] = []
  let mut total = 0
  while true {
    let chunk = file.read_until("\n") catch {
      e => {
        file.close()
        match e {
          @utf8.Malformed(_) => raise read_failure("decode", path)
          _ => raise read_failure("read", path)
        }
      }
    }
    match chunk {
      None => break
      Some(raw) => {
        total += 1
        if total > skip && lines.length() < take {
          lines.push(strip_trailing_cr(raw))
        }
      }
    }
  }
  file.close()
  { lines, total_lines: total, total_bytes }
}

///|
impl FsIo for NativeFsIo with fn read_lines(
  _self,
  path : String,
  skip : Int,
  take : Int,
) -> LinePage {
  native_read_lines(path, skip, take)
}

///|
/// Tail window via two streaming passes: count the file once, then re-read
/// skipping `total - take` lines. No ring buffer, obviously correct.
impl FsIo for NativeFsIo with fn read_last_lines(
  _self,
  path : String,
  take : Int,
) -> LinePage {
  let counted = native_read_lines(path, 0, 0)
  let take_eff = if take < counted.total_lines {
    take
  } else {
    counted.total_lines
  }
  native_read_lines(path, counted.total_lines - take_eff, take_eff)
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
  self : ReadTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_read_impl(NativeFsIo::{  }, self.freshness, self.anchor, call)
}
