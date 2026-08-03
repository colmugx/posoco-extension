///|
test "workspace resolves relative paths" {
  let workspace = match Workspace::new("/repo") {
    Ok(value) => value
    Err(reason) => fail(reason)
  }
  assert_eq(workspace.resolve("src/main.mbt"), Ok("/repo/src/main.mbt"))
  assert_eq(workspace.resolve("./src//main.mbt"), Ok("/repo/src/main.mbt"))
  assert_eq(workspace.resolve("."), Ok("/repo"))
}

///|
test "workspace rejects lexical escape" {
  let workspace = match Workspace::new("/repo") {
    Ok(value) => value
    Err(reason) => fail(reason)
  }
  assert_true(workspace.resolve("../secret") is Err(_))
  assert_true(workspace.resolve("src/../../secret") is Err(_))
  assert_true(workspace.resolve("/etc/passwd") is Err(_))
  assert_true(workspace.resolve("C:\\secret") is Err(_))
}

///|
test "workspace contributes project boundary prompt" {
  let workspace = match Workspace::new("/repo") {
    Ok(value) => value
    Err(reason) => fail(reason)
  }
  let manifest = workspace.manifest()
  assert_eq(manifest.prompt_contributors.length(), 1)
  assert_true(workspace.system_prompt().contains("/repo"))
}
