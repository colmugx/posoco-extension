///|
async fn prepare_directory(directory : String) -> Unit {
  @fs.mkdir(directory, recursive=true, allow_exist=true)
}
