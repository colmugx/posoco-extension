///|
// ============================================================================
// posoco_ext_read_js.mbt — js target (bun runtime) adaptor + ToolProvider impl.
//
// Active on: target="js"
// Provides:  Bun FFI bindings, JsFsIo adaptor (via Bun.file), and complete
//            ToolProvider impl
//
// Uses Bun's global `Bun.file` to stat + read. Bun is a global object under
// bun, so `extern "js" fn ... = #| () => Bun.xxx()` works without require/
// import. We deliberately do NOT use `node:fs`.
// ============================================================================

// ---------------------------------------------------------------------------
// Bun FFI bindings.
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

// ---------------------------------------------------------------------------
// JsFsIo — Bun-backed FsIo adaptor.
// ---------------------------------------------------------------------------

///|
priv struct JsFsIo {}

///|
/// exists() resolves false on missing file; a rejection here is a runtime
/// failure (permission, IO), not a missing file.
impl FsIo for JsFsIo with fn exists(_self, path : String) -> Bool {
  let file = bun_file(path)
  file.exists().wait() catch {
    _ => raise read_failure("stat", path)
  }
}

///|
/// text() reads + decodes UTF-8 in one shot. Rejection = IO or decode error.
impl FsIo for JsFsIo with fn read_text(_self, path : String) -> String {
  let file = bun_file(path)
  file.text().wait() catch {
    _ => raise read_failure("decode", path)
  }
}

// ---------------------------------------------------------------------------
// ToolProvider — complete impl (list_tools + execute) for js.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.ToolProvider for ReadTools with fn list_tools(
  _self : ReadTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `read` tool on js. Business logic lives in the shared
/// `execute_read_impl`; this method only supplies the Bun-backed adaptor.
pub impl @posoco.ToolProvider for ReadTools with fn execute(
  _self : ReadTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_read_impl(JsFsIo::{  }, call)
}
