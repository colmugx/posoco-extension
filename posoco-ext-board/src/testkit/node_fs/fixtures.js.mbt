///|
#module("node:os")
extern "js" fn os_tmpdir() -> String = "tmpdir"

///|
#module("node:fs")
extern "js" fn make_temp(prefix : String) -> String = "mkdtempSync"

///|
#module("node:fs")
extern "js" fn rm(path : String, options : Json) -> Unit = "rmSync"

///|
#module("node:fs")
extern "js" fn write(path : String, text : String) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn symlink(target : String, path : String) -> Unit = "symlinkSync"

///|
pub fn temporary_directory() -> String {
  make_temp(os_tmpdir() + "/posoco-board-js-")
}

///|
pub fn cleanup(directory : String) -> Unit {
  cleanup_ffi(rm, directory)
}

///|
extern "js" fn cleanup_ffi(
  remove : (String, Json) -> Unit,
  directory : String,
) -> Unit =
  #| (remove, directory) => remove(directory, {recursive: true, force: true})

///|
pub fn put(path : String, text : String) -> Unit {
  write(path, text)
}

///|
pub fn link(target : String, path : String) -> Unit {
  symlink(target, path)
}
