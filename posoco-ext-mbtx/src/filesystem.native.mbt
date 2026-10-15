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
  @fs.write_file(path, text)
}

///|
async fn remove_directory(path : String) -> Unit nocancel {
  @fs.rmdir(path, recursive=true)
}
