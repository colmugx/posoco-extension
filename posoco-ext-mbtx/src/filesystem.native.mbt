///|
async fn temporary_directory(prefix : String) -> String {
  @fs.realpath(@fs.tmpdir(prefix~))
}

///|
async fn canonical_path(path : String) -> String {
  @fs.realpath(path)
}

///|
async fn write_text(path : String, text : String) -> Unit {
  @fs.write_text(path, text)
}

///|
async fn remove_directory(path : String) -> Unit nocancel {
  @fs.rmdir(path, recursive=true)
}

///|
/// Preserve source mtime on cache hits to allow Moon's no-op build.
async fn write_text_if_changed(path : String, source : String) -> Unit {
  let same = (@fs.read_text(path) == source) catch { _ => false }
  if !same {
    @fs.write_text(path, source)
  }
}

///|
async fn copy_build_artifact(from : String, to : String) -> Unit {
  @fs.write_binary(to, @fs.read_binary(from))
}
