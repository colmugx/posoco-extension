///|
/// Native implementation uses moonbitlang/async/fs. The lock is a directory
/// so JS/Bun and native builds coordinate on the same artifact.
fn mbtx_is_windows() -> Bool {
  @async.platform is Windows
}

///|
async fn tc_fs_mkdir(path : String) -> Unit {
  @fs.mkdir(path, recursive=true, allow_exist=true)
}

///|
async fn tc_fs_try_lock(path : String) -> Bool {
  try {
    @fs.mkdir(path)
    true
  } catch {
    _ => false
  }
}

///|
async fn tc_fs_unlock(path : String) -> Unit nocancel {
  @fs.rmdir(path) catch {
    _ => ()
  }
}

///|
async fn tc_fs_remove(path : String) -> Unit nocancel {
  @fs.rmdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
async fn tc_fs_exists(path : String) -> Bool {
  @fs.exists(path)
}

///|
async fn tc_fs_copy_executable(source : String, destination : String) -> Unit {
  @fs.write_file(destination, @fs.read_file(source))
  if !mbtx_is_windows() {
    @fs.chmod(destination, 0o755)
  }
}

///|
async fn tc_fs_rename(source : String, destination : String) -> Unit {
  @fs.rename(source, destination, replace=true)
}
