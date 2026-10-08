///|
let fixture_names : Array[String] = [
  "snapshot", "task-created", "task-updated", "attempt-started", "attempt-finished",
  "telemetry", "command-result", "resync-required", "protocol-error",
]

///|
/// Test-only Eq assertion for the client read models, which intentionally
/// derive `Eq` without `Debug`. Same equality contract as the builtin
/// `assert_eq`; failures are reported at the call site.
#callsite(autofill(loc))
fn[T : Eq] assert_eq_eq(
  actual : T,
  expected : T,
  loc~ : SourceLoc,
) -> Unit raise {
  if actual != expected {
    fail("assertion failed: actual == expected", loc~)
  }
}

///|
// Moon may run native tests from a package, workspace, or build directory.
// Resolve at runtime rather than baking a developer's checkout into the test.
async fn locate_fixtures(
  env_source : (String) -> String?,
  working_dir : String,
) -> String {
  match env_source("POSOCO_BOARD_FIXTURES") {
    Some(directory) => {
      assert_true(@fs.exists(directory + "/snapshot.json"))
      return directory
    }
    None => ()
  }
  let mut directory = @fs.realpath(working_dir)
  let mut depth = 0
  while depth < 32 {
    for
      suffix in [
        "/protocol-fixtures/v1", "/posoco-ext-board/protocol-fixtures/v1", "/extension/posoco-ext-board/protocol-fixtures/v1",
        "/external/cetas/extension/posoco-ext-board/protocol-fixtures/v1",
      ] {
      let candidate = directory + suffix
      if @fs.exists(candidate + "/snapshot.json") {
        return candidate
      }
    }
    let parent = @fs.realpath(directory + "/..")
    if parent == directory {
      fail(
        "Cannot locate protocol-fixtures/v1; set POSOCO_BOARD_FIXTURES to the fixture directory",
      )
    }
    directory = parent
    depth = depth + 1
  }
  fail("Exhausted ancestors searching for protocol-fixtures/v1")
}

///|
async fn fixture_directory() -> String {
  let cwd = match @env.current_dir() {
    Some(value) => value
    None => fail("Native fixture tests require a working directory")
  }
  locate_fixtures(@env.get_env_var, cwd)
}

///|
async fn fixture_text(directory : String, name : String) -> String {
  @fs.read_file(directory + "/" + name + ".json").text()
}

///|
fn decode_fixture(
  name : String,
  text : String,
) -> @protocol.BoardServerFrame raise {
  match @protocol.decode_server_frame(text) {
    Ok(frame) => frame
    Err(_) => fail("Invalid canonical fixture: \{name}")
  }
}

///|
async fn fixture_frame(
  directory : String,
  name : String,
) -> @protocol.BoardServerFrame {
  decode_fixture(name, fixture_text(directory, name))
}

///|
async test "fixture locator supports ancestor search and an injected environment source" {
  let directory = fixture_directory()
  let resolved = @fs.realpath(directory)
  assert_eq(@fs.realpath(locate_fixtures(_ => None, resolved)), resolved)
  let requested = Ref("")
  let source = key => {
    requested.val = key
    Some(directory)
  }
  assert_eq(locate_fixtures(source, "."), directory)
  assert_eq(requested.val, "POSOCO_BOARD_FIXTURES")
}

///|
async test "invalid environment override fails instead of loading another copy" {
  let outcome : Result[String, Error] = Ok(
    locate_fixtures(_ => Some("./nowhere"), "."),
  ) catch {
    failure => Err(failure)
  }
  assert_true(outcome is Err(_))
}

///|
async test "all canonical v1 files round trip as frames and semantic JSON" {
  let directory = fixture_directory()
  for name in fixture_names {
    let raw = fixture_text(directory, name)
    let frame = decode_fixture(name, raw)
    let encoded = @protocol.encode_server_frame(frame)
    assert_eq(@protocol.decode_server_frame(encoded), Ok(frame))
    assert_eq(@json.parse(encoded), @json.parse(raw))
  }
}
