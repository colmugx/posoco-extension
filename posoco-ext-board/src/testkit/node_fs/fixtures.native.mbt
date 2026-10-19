///|
pub async fn temporary_directory() -> String {
  @fs.tmpdir(prefix="posoco-board-service-")
}

///|
pub async fn cleanup(directory : String) -> Unit {
  @fs.rmdir(directory, recursive=true)
}

///|
pub async fn put(path : String, text : String) -> Unit {
  @fs.write_file(path, text)
}
