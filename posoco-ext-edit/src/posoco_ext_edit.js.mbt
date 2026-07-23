///|
/// posoco_ext_edit.js.mbt — js target (bun runtime) implementation.
///
/// Provides the FsIo adaptor (backed by Bun globals) and the EditTools struct
/// + ToolProvider impl that delegates business logic to `execute_edit_impl`.

// ---------------------------------------------------------------------------
// Bun FFI bindings (same shape as ext-read + ext-write).
// ---------------------------------------------------------------------------

///|
#external
priv type BunFile

///|
extern "js" fn bun_file(path : String) -> BunFile =
  #| (path) => Bun.file(path)

///|
extern "js" fn BunFile::exists(self : BunFile) -> @js_async.Promise[Bool] =
  #| (file) => file.exists()

///|
extern "js" fn BunFile::text(self : BunFile) -> @js_async.Promise[String] =
  #| (file) => file.text()

///|
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
// EditTools — js struct + ToolProvider impl.
// ---------------------------------------------------------------------------

///|
/// EditTools — file editing tool provider (js target).
pub(all) struct EditTools {}

///|
pub fn EditTools::new() -> EditTools {
  EditTools::{  }
}

///|
pub impl @posoco.ToolProvider for EditTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  shared_list_tools()
}

///|
/// Execute the `edit` tool on js. Business logic lives in the shared
/// `execute_edit_impl`; this method only supplies the Bun-backed adaptor.
pub impl @posoco.ToolProvider for EditTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  execute_edit_impl(JsFsIo::{  }, call)
}
