///|
/// Injected env/exists fakes drive every discovery branch; nothing here
/// touches the real host environment.

///|
fn config_env_of(pairs : Array[(String, String)]) -> (String) -> String? {
  fn(key : String) -> String? {
    let mut hit : String? = None
    for kv in pairs {
      if kv.0 == key {
        hit = Some(kv.1)
      }
    }
    hit
  }
}

///|
fn config_exists_only(paths : Array[String]) -> (String) -> Bool {
  fn(p : String) -> Bool { paths.contains(p) }
}

///|
test "config_defaults" {
  let config = zcode_config()
  assert_true(config.bin is None)
  assert_true(config.node is None)
  assert_true(config.creds_path is None)
  assert_eq(config.default_mode, "edit")
  assert_eq(config.timeout_ms, 1_800_000)
}

///|
test "check_mode_accepts_documented_modes" {
  for mode in ["build", "edit", "plan", "yolo"] {
    match zcode_check_mode(mode) {
      Ok(m) => assert_eq(m, mode)
      Err(e) => fail(e)
    }
  }
}

///|
test "check_mode_rejects_unknown_mode" {
  match zcode_check_mode("agentic") {
    Err(message) => {
      assert_true(message.contains("agentic"))
      assert_true(message.contains("build|edit|plan|yolo"))
    }
    Ok(_) => fail("expected mode rejection")
  }
}

///|
test "resolve_explicit_bin_without_node_prefixing" {
  let config = { ..zcode_config(), bin: Some("/usr/local/bin/zcode"), }
  match
    zcode_resolve_command(
      config~,
      env=config_env_of([]),
      exists=config_exists_only([]),
    ) {
    Ok((program, args)) => {
      assert_eq(program, "/usr/local/bin/zcode")
      assert_eq(args.length(), 2)
      assert_eq(args[0], "app-server")
      assert_eq(args[1], "--stdio")
    }
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_prefers_config_bin_over_env_and_path" {
  let config = { ..zcode_config(), bin: Some("/opt/first/zcode"), }
  let env = config_env_of([
    ("ZCODE_BIN", "/opt/second/zcode"),
    ("PATH", "/usr/bin"),
  ])
  match
    zcode_resolve_command(
      config~,
      env~,
      exists=config_exists_only(["/usr/bin/zcode"]),
    ) {
    Ok((program, _args)) => assert_eq(program, "/opt/first/zcode")
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_env_zcode_bin_beats_path" {
  let config = zcode_config()
  let env = config_env_of([
    ("ZCODE_BIN", "/opt/zcode/bin/zcode"),
    ("PATH", "/usr/bin"),
  ])
  match
    zcode_resolve_command(
      config~,
      env~,
      exists=config_exists_only(["/usr/bin/zcode"]),
    ) {
    Ok((program, args)) => {
      assert_eq(program, "/opt/zcode/bin/zcode")
      assert_eq(args[0], "app-server")
    }
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_path_lookup_hits_zcode" {
  let config = zcode_config()
  let env = config_env_of([("PATH", "/bin:/usr/local/bin:/opt/homebrew/bin")])
  match
    zcode_resolve_command(
      config~,
      env~,
      exists=config_exists_only(["/opt/homebrew/bin/zcode"]),
    ) {
    Ok((program, args)) => {
      assert_eq(program, "zcode")
      assert_eq(args.length(), 2)
      assert_eq(args[0], "app-server")
    }
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_darwin_bundle_gets_node_prefix" {
  let config = zcode_config()
  let env = config_env_of([("PATH", "/bin")])
  let bundle = "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"
  match
    zcode_resolve_command(config~, env~, exists=config_exists_only([bundle])) {
    Ok((program, args)) => {
      assert_eq(program, "node")
      assert_eq(args.length(), 3)
      assert_eq(args[0], bundle)
      assert_eq(args[1], "app-server")
      assert_eq(args[2], "--stdio")
    }
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_cjs_uses_zcode_node_env" {
  let config = zcode_config()
  let env = config_env_of([
    ("ZCODE_NODE", "/opt/node/bin/node"),
    ("PATH", "/bin"),
  ])
  let bundle = "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"
  match
    zcode_resolve_command(config~, env~, exists=config_exists_only([bundle])) {
    Ok((program, args)) => {
      assert_eq(program, "/opt/node/bin/node")
      assert_eq(args[0], bundle)
    }
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_config_node_beats_zcode_node_env" {
  let config = {
    ..zcode_config(),
    bin: Some("/tmp/zcode.cjs"),
    node: Some("/usr/local/bin/node"),
  }
  let env = config_env_of([("ZCODE_NODE", "/opt/node/bin/node")])
  match zcode_resolve_command(config~, env~, exists=config_exists_only([])) {
    Ok((program, args)) => {
      assert_eq(program, "/usr/local/bin/node")
      assert_eq(args[0], "/tmp/zcode.cjs")
    }
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_windows_bundle_via_localappdata" {
  let config = zcode_config()
  let env = config_env_of([
    ("PATH", "/bin"),
    ("LOCALAPPDATA", "C:\\Users\\dev\\AppData\\Local"),
  ])
  let bundle = "C:\\Users\\dev\\AppData\\Local\\Programs\\ZCode\\resources\\glm\\zcode.cjs"
  match
    zcode_resolve_command(config~, env~, exists=config_exists_only([bundle])) {
    Ok((program, args)) => {
      assert_eq(program, "node")
      assert_eq(args[0], bundle)
    }
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_linux_bundle_via_install_dir" {
  let config = zcode_config()
  let env = config_env_of([
    ("PATH", "/bin"),
    ("ZCODE_INSTALL_DIR", "/opt/zcode"),
  ])
  let bundle = "/opt/zcode/resources/glm/zcode.cjs"
  match
    zcode_resolve_command(config~, env~, exists=config_exists_only([bundle])) {
    Ok((program, args)) => {
      assert_eq(program, "node")
      assert_eq(args[0], bundle)
    }
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_all_miss_yields_bin_not_found" {
  match
    zcode_resolve_command(
      config=zcode_config(),
      env=config_env_of([]),
      exists=config_exists_only([]),
    ) {
    Err(ZcodeBinNotFound) => ()
    Ok(_) => fail("expected ZcodeBinNotFound")
    Err(other) => fail(Show::to_string(other))
  }
}

///|
test "creds_path_priority_config_env_home" {
  let explicit = { ..zcode_config(), creds_path: Some("/cfg/zcode.json"), }
  assert_eq(
    zcode_creds_path(config=explicit, env=config_env_of([])),
    "/cfg/zcode.json",
  )
  let env = config_env_of([("ZCODE_CREDS", "/env/zcode.json")])
  assert_eq(zcode_creds_path(config=zcode_config(), env~), "/env/zcode.json")
  let home = config_env_of([("HOME", "/Users/dev")])
  assert_eq(
    zcode_creds_path(config=zcode_config(), env=home),
    "/Users/dev/.zcode/v2/config.json",
  )
  assert_eq(
    zcode_creds_path(config=zcode_config(), env=config_env_of([])),
    "/.zcode/v2/config.json",
  )
}
