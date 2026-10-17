///|
#external
priv type ToolchainFsOptions

///|
extern "js" fn toolchain_recursive_options() -> ToolchainFsOptions =
  #| () => ({recursive: true})

///|
extern "js" fn toolchain_remove_options() -> ToolchainFsOptions =
  #| () => ({recursive: true, force: true})

///|
/// Synchronous Node filesystem operations are quick metadata changes; the
/// long-running download and compilation are async process operations.
#module("node:fs")
extern "js" fn mbtx_node_mkdir(path : String, options : ToolchainFsOptions) -> Unit = "mkdirSync"

///|
#module("node:fs")
extern "js" fn mbtx_node_exists(path : String) -> Bool = "existsSync"

///|
#module("node:fs")
extern "js" fn mbtx_node_remove(path : String, options : ToolchainFsOptions) -> Unit = "rmSync"

///|
#module("node:fs")
extern "js" fn mbtx_node_copy(source : String, destination : String) -> Unit = "copyFileSync"

///|
#module("node:fs")
extern "js" fn mbtx_node_chmod(path : String, mode : Int32) -> Unit = "chmodSync"

///|
#module("node:fs")
extern "js" fn mbtx_node_rename(source : String, destination : String) -> Unit = "renameSync"

///|
extern "js" fn mbtx_node_platform_windows() -> Bool =
  #| () => process.platform === "win32"

///|
extern "js" fn mbtx_node_try_mkdir(
  mkdir : (String, ToolchainFsOptions) -> Unit,
  path : String,
) -> Bool =
  #| (mkdir, path) => {
  #|   try { mkdir(path, { recursive: false }); return true; }
  #|   catch (e) { if (e && e.code === "EEXIST") return false; throw e; }
  #| }

///|
fn mbtx_is_windows() -> Bool {
  mbtx_node_platform_windows()
}

///|
fn tc_fs_mkdir(path : String) -> Unit {
  mbtx_node_mkdir(path, toolchain_recursive_options())
}

///|
fn tc_fs_try_lock(path : String) -> Bool {
  mbtx_node_try_mkdir(mbtx_node_mkdir, path)
}

///|
fn tc_fs_unlock(path : String) -> Unit {
  mbtx_node_remove(path, toolchain_remove_options())
}

///|
fn tc_fs_remove(path : String) -> Unit {
  mbtx_node_remove(path, toolchain_remove_options())
}

///|
fn tc_fs_exists(path : String) -> Bool {
  mbtx_node_exists(path)
}

///|
fn tc_fs_copy_executable(source : String, destination : String) -> Unit {
  mbtx_node_copy(source, destination)
  if !mbtx_is_windows() {
    mbtx_node_chmod(destination, 0o755)
  }
}

///|
fn tc_fs_rename(source : String, destination : String) -> Unit {
  mbtx_node_rename(source, destination)
}
