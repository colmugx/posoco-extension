///|
#external
priv type HandoffJsResult

///|
extern "js" fn HandoffJsResult::is_ok(self : Self) -> Bool =
  #| (result) => result.ok

///|
extern "js" fn HandoffJsResult::content(self : Self) -> String =
  #| (result) => result.content

///|
/// node:fs members bound with `#module` and injected into the inline-JS
/// wrappers as values (pattern follows posoco-ext-workspace fs_port.js.mbt /
/// moonbitlang/x/fs/fs_js.mbt). existsSync never throws.
#module("node:fs")
extern "js" fn fs_exists_sync(path : String) -> Bool = "existsSync"

///|
#module("node:fs")
extern "js" fn fs_read_text_sync(path : String, encoding : String) -> String = "readFileSync"

///|
/// mkdirSync's 2nd argument is a JS options object, so the declared 2nd
/// parameter is only a value-passing shape; the wrapper builds
/// `{ recursive: true }` on the JS side.
#module("node:fs")
extern "js" fn fs_mkdir_sync(path : String, recursive : Bool) -> Unit = "mkdirSync"

///|
#module("node:fs")
extern "js" fn fs_write_file_sync(path : String, data : String) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn fs_rename_sync(old_path : String, new_path : String) -> Unit = "renameSync"

///|
#module("node:fs")
extern "js" fn fs_unlink_sync(path : String) -> Unit = "unlinkSync"

///|
extern "js" fn handoff_store_read_ffi(
  read_text : (String, String) -> String,
  path : String,
) -> HandoffJsResult =
  #| (readFile, path) => {
  #|   try {
  #|     return { ok: true, content: readFile(path, "utf8") };
  #|   } catch (error) {
  #|     return { ok: false, content: String(error?.message ?? error) };
  #|   }
  #| }

///|
extern "js" fn handoff_store_mkdir_ffi(
  mkdir : (String, Bool) -> Unit,
  path : String,
) -> HandoffJsResult =
  #| (mkdir, path) => {
  #|   try {
  #|     mkdir(path, { recursive: true });
  #|     return { ok: true, content: "" };
  #|   } catch (error) {
  #|     return { ok: false, content: String(error?.message ?? error) };
  #|   }
  #| }

///|
extern "js" fn handoff_store_write_atomic_ffi(
  write_file : (String, String) -> Unit,
  rename : (String, String) -> Unit,
  unlink : (String) -> Unit,
  path : String,
  content : String,
) -> HandoffJsResult =
  #| (writeFile, rename, unlink, path, content) => {
  #|   const suffix = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  #|   const tmp = `${path}.tmp-${suffix}`;
  #|   try {
  #|     writeFile(tmp, content, { encoding: "utf8", mode: 0o644 });
  #|     rename(tmp, path);
  #|     return { ok: true, content: "" };
  #|   } catch (error) {
  #|     try { unlink(tmp); } catch {}
  #|     return { ok: false, content: String(error?.message ?? error) };
  #|   }
  #| }

///|
pub impl HandoffStore for DefaultHandoffStore with fn exists(_self, path) {
  Ok(fs_exists_sync(path))
}

///|
pub impl HandoffStore for DefaultHandoffStore with fn read(_self, path) {
  let result = handoff_store_read_ffi(fs_read_text_sync, path)
  if result.is_ok() {
    Ok(result.content())
  } else {
    Err("handoff store read failed: " + result.content())
  }
}

///|
pub impl HandoffStore for DefaultHandoffStore with fn ensure_dir(_self, path) {
  let result = handoff_store_mkdir_ffi(fs_mkdir_sync, path)
  if result.is_ok() {
    Ok(())
  } else {
    Err("handoff store mkdir failed: " + result.content())
  }
}

///|
pub impl HandoffStore for DefaultHandoffStore with fn write_atomic(
  _self,
  path,
  content,
) {
  let result = handoff_store_write_atomic_ffi(
    fs_write_file_sync, fs_rename_sync, fs_unlink_sync, path, content,
  )
  if result.is_ok() {
    Ok(())
  } else {
    Err("handoff store write failed: " + result.content())
  }
}

///|
pub extend DefaultHandoffStore with HandoffStore::{
  read,
  write_atomic,
  ensure_dir,
  exists,
}
