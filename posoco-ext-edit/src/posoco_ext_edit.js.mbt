///|
// ============================================================================
// posoco_ext_edit_js.mbt — js target (bun runtime) adaptor + ToolProvider impl.
//
// Active on: target="js"
// Provides:  Bun FFI bindings, JsFsIo adaptor (via Bun.file + Bun.write), and
//            complete ToolProvider impl
//
// Uses Bun's global `Bun.file` to stat + read and `Bun.write` to write. Bun is
// a global object under bun, so `extern "js" fn ... = #| () => Bun.xxx()` works
// without require/import. We deliberately do NOT use `node:fs`.
// ============================================================================

// ---------------------------------------------------------------------------
// Bun FFI bindings (same shape as ext-read + ext-write).
// ---------------------------------------------------------------------------

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
/// `Bun.write(path, data)` returns Promise<number> (bytes written).
extern "js" fn bun_write_string(
  path : String,
  data : String,
) -> @js_async.Promise[Int] =
  #| (path, data) => Bun.write(path, data)

// ---------------------------------------------------------------------------
// JsFsIo — Bun-backed FsIo adaptor.
// ---------------------------------------------------------------------------

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
impl FsIo for JsFsIo with fn read_text(_self, path : String) -> String {
  let file = bun_file(path)
  file.text().wait() catch {
    _ => raise edit_failure("decode", path)
  }
}

///|
impl FsIo for JsFsIo with fn write_text(_self, path : String, content : String) -> Unit {
  let _bytes = bun_write_string(path, content).wait() catch {
    _ => raise edit_failure("write", path)
  }
}

// ---------------------------------------------------------------------------
// ToolProvider — complete impl (list_tools + execute) for js.
// ---------------------------------------------------------------------------

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
  _self : EditTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_edit_impl(JsFsIo::{  }, call)
}
