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
  @fs.write_text(path, text)
}

///|
async fn fixture_remove(path : String) -> Unit nocancel {
  @fs.rmdir(path, recursive=true)
}

///|
async fn fixture_compile(path : String) -> String {
  let result = @process.run(
    "moon",
    ["run", "--build-only", "--target", "wasm", "--output-json", path],
    stdout=Collect,
    stderr=Collect,
  )
  if result.exit_code != 0 {
    fail(result.stdout_text() + result.stderr_text())
  }
  result.stdout_text()
}
