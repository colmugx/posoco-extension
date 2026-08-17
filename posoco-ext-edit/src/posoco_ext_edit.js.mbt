///|
// Bun is a global object under bun, so `extern "js" fn ... = #| () => Bun.xxx()`
// works without require/import. We deliberately do NOT use `node:fs`.
// Same shape as ext-read + ext-write.

///|
/// Bun's opaque BunFile handle.
#external
priv type BunFile

///|
/// `Bun.file(path)` returns a BunFile. Synchronous in bun.
extern "js" fn bun_file(path : String) -> BunFile =
  #| (path) => Bun.file(path)

///|
/// `BunFile.prototype.exists()` — Promise<boolean>.
extern "js" fn BunFile::exists(self : BunFile) -> @js_async.Promise[Bool] =
  #| (file) => file.exists()

///|
/// `BunFile.prototype.text()` — Promise<string>.
extern "js" fn BunFile::text(self : BunFile) -> @js_async.Promise[String] =
  #| (file) => file.text()

///|
/// `BunFile.prototype.size` — getter, Promise<number> (bytes).
extern "js" fn BunFile::size(self : BunFile) -> @js_async.Promise[Double] =
  #| (file) => file.size

///|
/// `BunFile.prototype.lastModified` — getter, Promise<number> (epoch ms).
extern "js" fn BunFile::lastModified(
  self : BunFile,
) -> @js_async.Promise[Double] =
  #| (file) => file.lastModified

///|
/// `Bun.write(path, data)` returns Promise<number> (bytes written).
extern "js" fn bun_write_string(
  path : String,
  data : String,
) -> @js_async.Promise[Int] =
  #| (path, data) => Bun.write(path, data)

///|
/// `Bun.file(src).move(dest)` — atomic rename within the same filesystem,
/// Promise<boolean>.
extern "js" fn bun_move(src : String, dest : String) -> @js_async.Promise[Bool] =
  #| (src, dest) => Bun.file(src).move(dest)

///|
/// `Date.now()` — unique-enough temp suffix component.
extern "js" fn bun_now_ms() -> Int =
  #| () => Date.now()

///|
priv struct JsFsIo {}

///|
impl FsIo for JsFsIo with fn exists(_self, path : String) -> Bool {
  let file = bun_file(path)
  file.exists().wait() catch {
    _ => raise edit_failure("stat", path)
  }
}

///|
/// Stamp from Bun's `size`/`lastModified` getters (ms granularity; the
/// guard only compares stamps from the same runtime).
impl FsIo for JsFsIo with fn stat(_self, path : String) -> @devkit.FileStamp {
  let file = bun_file(path)
  let size = file.size().wait() catch { _ => raise edit_failure("stat", path) }
  let ms = file.lastModified().wait() catch {
      _ => raise edit_failure("stat", path)
    }
  let mtime_s = (ms / 1000.0).to_int64()
  let mtime_ns = (ms % 1000.0 * 1_000_000.0).to_int()
  { mtime_s, mtime_ns, size: size.to_int64() }
}

///|
impl FsIo for JsFsIo with fn read_text(_self, path : String) -> String {
  let file = bun_file(path)
  file.text().wait() catch {
    _ => raise edit_failure("decode", path)
  }
}

///|
/// Atomic write: sibling temp file, then `move()` (rename(2)) over target.
impl FsIo for JsFsIo with fn write_atomic(
  _self,
  path : String,
  content : String,
) -> Unit {
  let tmp = "\{path}.tmp-\{bun_now_ms()}"
  let _bytes = bun_write_string(tmp, content).wait() catch {
    _ => raise edit_failure("write", path)
  }
  let _moved = bun_move(tmp, path).wait() catch {
    _ => raise edit_failure("write", path)
  }
  ()
}

///|
pub impl @posoco.ToolProvider for EditTools with fn list_tools(
  _self : EditTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `edit` tool on js. Business logic lives in the shared
/// `execute_edit_impl`; this method only supplies the Bun-backed adaptor.
pub impl @posoco.ToolProvider for EditTools with fn execute(
  self : EditTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_edit_impl(JsFsIo::{  }, self.freshness, call)
}
