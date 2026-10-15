///|
async fn fixture_directory() -> String {
  @fs.realpath(@fs.tmpdir(prefix="mbtx-sdk-test-"))
}

///|
async fn fixture_realpath(path : String) -> String {
  @fs.realpath(path)
}

///|
async fn fixture_mkdir(path : String) -> Unit {
  @fs.mkdir(path, recursive=true)
}

///|
async fn fixture_write(path : String, text : String) -> Unit {
  @fs.write_file(path, text)
}

///|
async fn fixture_remove(path : String) -> Unit nocancel {
  @fs.rmdir(path, recursive=true)
}

///|
async fn fixture_compile(path : String) -> String {
  let (code, stdout, stderr) = @process.collect_output("moon", [
    "run", "--build-only", "--target", "wasm", "--output-json", path,
  ])
  if code != 0 {
    fail(stdout.text() + stderr.text())
  }
  stdout.text()
}
