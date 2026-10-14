///|
async fn temporary_directory(prefix : String) -> String {
  @fs.realpath(@fs.tmpdir(prefix~))
}

///|
async fn read_text(path : String) -> String {
  @fs.read_file(path).text()
}

///|
async fn write_text(path : String, text : String) -> Unit {
  @fs.write_file(path, text)
}

///|
async fn make_directory(path : String) -> Unit {
  @fs.mkdir(path, recursive=true, allow_exist=true)
}

///|
async fn remove_directory(path : String) -> Unit nocancel {
  @fs.rmdir(path, recursive=true)
}

///|
async fn list_directory(path : String) -> Array[String] {
  @fs.readdir(path, sort=true)
}

///|
async fn path_kind(path : String) -> String {
  match @fs.kind(path, follow_symlink=false) {
    Regular => "file"
    Directory => "directory"
    _ => raise Failure::Failure("unsupported build resource kind: " + path)
  }
}
