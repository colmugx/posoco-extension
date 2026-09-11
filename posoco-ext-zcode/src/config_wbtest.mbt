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
  let profile = config_env_of([("USERPROFILE", "C:\\Users\\dev")])
  assert_eq(
    zcode_creds_path(config=zcode_config(), env=profile),
    "C:\\Users\\dev/.zcode/v2/config.json",
  )
  assert_eq(
    zcode_creds_path(config=zcode_config(), env=config_env_of([])),
    "/.zcode/v2/config.json",
  )
}

///|
/// Candidate enumeration and the async detect helper.

///|
test "candidate_paths_empty_when_bin_or_env_trusted" {
  let config = { ..zcode_config(), bin: Some("/opt/first/zcode"), }
  assert_eq(zcode_candidate_paths(config~, env=config_env_of([])), [])
  let env = config_env_of([("ZCODE_BIN", "/opt/env/zcode")])
  assert_eq(zcode_candidate_paths(config=zcode_config(), env~), [])
}

///|
test "candidate_paths_darwin_order" {
  let env = config_env_of([("PATH", "/bin:/usr/local/bin")])
  assert_eq(zcode_candidate_paths(config=zcode_config(), env~), [
    "/bin/zcode", "/usr/local/bin/zcode", "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
    "/opt/ZCode/resources/glm/zcode.cjs", "/usr/share/zcode/resources/glm/zcode.cjs",
  ])
}

///|
test "candidate_paths_bundles_appended_per_env_root" {
  let darwin = "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"
  let full = config_env_of([
    ("PATH", "/bin"),
    ("LOCALAPPDATA", "C:\\Users\\dev\\AppData\\Local"),
    ("ZCODE_INSTALL_DIR", "/opt/zcode"),
  ])
  assert_eq(zcode_candidate_paths(config=zcode_config(), env=full), [
    "/bin/zcode", darwin, "C:\\Users\\dev\\AppData\\Local\\Programs\\ZCode\\resources\\glm\\zcode.cjs",
    "/opt/ZCode/resources/glm/zcode.cjs", "/usr/share/zcode/resources/glm/zcode.cjs",
    "/opt/zcode/resources/glm/zcode.cjs",
  ])
  let partial = config_env_of([("ZCODE_INSTALL_DIR", "/opt/zcode")])
  assert_eq(zcode_candidate_paths(config=zcode_config(), env=partial), [
    darwin, "/opt/ZCode/resources/glm/zcode.cjs", "/usr/share/zcode/resources/glm/zcode.cjs",
    "/opt/zcode/resources/glm/zcode.cjs",
  ])
}

///|
test "candidate_paths_without_path_env_lists_bundles_only" {
  assert_eq(
    zcode_candidate_paths(config=zcode_config(), env=config_env_of([])),
    [
      "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs", "/opt/ZCode/resources/glm/zcode.cjs",
      "/usr/share/zcode/resources/glm/zcode.cjs",
    ],
  )
}

///|
test "candidate_paths_windows_path_semicolon_and_shims" {
  let env = config_env_of([("OS", "Windows_NT"), ("PATH", "C:\\tools;D:\\apps")])
  assert_eq(zcode_candidate_paths(config=zcode_config(), env~), [
    "C:\\tools\\zcode", "C:\\tools\\zcode.exe", "C:\\tools\\zcode.cmd", "D:\\apps\\zcode",
    "D:\\apps\\zcode.exe", "D:\\apps\\zcode.cmd", "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
    "/opt/ZCode/resources/glm/zcode.cjs", "/usr/share/zcode/resources/glm/zcode.cjs",
  ])
}

///|
test "candidate_paths_windows_detected_via_program_files" {
  let env = config_env_of([
    ("ProgramFiles", "C:\\Program Files"),
    ("ProgramFiles(x86)", "C:\\Program Files (x86)"),
  ])
  let paths = zcode_candidate_paths(config=zcode_config(), env~)
  assert_true(
    paths.contains("C:\\Program Files\\ZCode\\resources\\glm\\zcode.cjs"),
  )
  assert_true(
    paths.contains("C:\\Program Files (x86)\\ZCode\\resources\\glm\\zcode.cjs"),
  )
  // ProgramFiles presence alone selects the windows PATH shape.
  let win = config_env_of([
    ("PATH", "C:\\x;C:\\y"),
    ("ProgramFiles", "C:\\Program Files"),
  ])
  assert_true(
    zcode_candidate_paths(config=zcode_config(), env=win).contains(
      "C:\\x\\zcode.exe",
    ),
  )
}

///|
test "candidate_paths_localappdata_falls_back_to_home" {
  let env = config_env_of([("USERPROFILE", "C:\\Users\\dev")])
  let paths = zcode_candidate_paths(config=zcode_config(), env~)
  assert_true(
    paths.contains(
      "C:\\Users\\dev\\AppData\\Local\\Programs\\ZCode\\resources\\glm\\zcode.cjs",
    ),
  )
  let explicit = config_env_of([
    ("USERPROFILE", "C:\\Users\\dev"),
    ("LOCALAPPDATA", "D:\\Local"),
  ])
  assert_true(
    zcode_candidate_paths(config=zcode_config(), env=explicit).contains(
      "D:\\Local\\Programs\\ZCode\\resources\\glm\\zcode.cjs",
    ),
  )
}

///|
test "candidate_paths_darwin_home_bundle" {
  let env = config_env_of([("HOME", "/Users/dev")])
  assert_eq(zcode_candidate_paths(config=zcode_config(), env~), [
    "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs", "/Users/dev/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
    "/Users/dev\\AppData\\Local\\Programs\\ZCode\\resources\\glm\\zcode.cjs", "/opt/ZCode/resources/glm/zcode.cjs",
    "/usr/share/zcode/resources/glm/zcode.cjs",
  ])
}

///|
test "candidate_paths_skips_empty_path_entries" {
  let env = config_env_of([("PATH", ":/bin:")])
  assert_eq(zcode_candidate_paths(config=zcode_config(), env~), [
    "/bin/zcode", "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs", "/opt/ZCode/resources/glm/zcode.cjs",
    "/usr/share/zcode/resources/glm/zcode.cjs",
  ])
  let win = config_env_of([("OS", "Windows_NT"), ("PATH", ";C:\\bin;")])
  let paths = zcode_candidate_paths(config=zcode_config(), env=win)
  assert_eq(paths[0], "C:\\bin\\zcode")
}

///|
test "desktop_exec_paths_parses_quotes_args_field_codes_crlf" {
  assert_eq(
    zcode_desktop_exec_paths("[Desktop Entry]\nExec=/opt/App/zcode %U\n"),
    ["/opt/App/zcode"],
  )
  assert_eq(
    zcode_desktop_exec_paths(
      "[Desktop Entry]\nExec=\"/opt/My App/zcode\" --new-window %U\n",
    ),
    ["/opt/My App/zcode"],
  )
  assert_eq(
    zcode_desktop_exec_paths("[Desktop Entry]\r\nExec=/usr/bin/zcode\r\n"),
    ["/usr/bin/zcode"],
  )
  assert_eq(
    zcode_desktop_exec_paths(
      "[Desktop Entry]\nTryExec=/wrong/zcode\nExec=/right/zcode\n",
    ),
    ["/right/zcode"],
  )
  assert_eq(
    zcode_desktop_exec_paths("[Desktop Entry]\nExec=/a/zcode\nExec=/b/zcode\n"),
    ["/a/zcode", "/b/zcode"],
  )
  assert_eq(zcode_desktop_exec_paths("[Desktop Entry]\nName=ZCode\n"), [])
  assert_eq(zcode_desktop_exec_paths("[Desktop Entry]\nExec=\n"), [])
  assert_eq(zcode_desktop_exec_paths(""), [])
}

///|
test "sibling_candidates_around_resolved_path" {
  assert_eq(zcode_sibling_candidates("/opt/Zed/bin/zcode"), [
    "/opt/Zed/bin/zcode.cjs", "/opt/Zed/bin/../resources/glm/zcode.cjs", "/opt/Zed/bin/resources/glm/zcode.cjs",
  ])
  assert_eq(zcode_sibling_candidates("zcode"), [])
  assert_eq(zcode_sibling_candidates("/zcode"), [])
}

///|
async test "desktop_candidates_scan_xdg_and_home_dirs" {
  let env = config_env_of([
    ("XDG_DATA_DIRS", "/xdg1:/xdg2"),
    ("HOME", "/home/dev"),
  ])
  let files : Map[String, Array[String]] = Map::from_array([
    ("/home/dev/.local/share/applications", ["zcode-user.desktop"]),
    ("/xdg1/applications", ["ZCode.desktop", "notes.txt", "other-zcode.txt"]),
    ("/xdg2/applications", []),
  ])
  let contents : Map[String, String] = Map::from_array([
    (
      "/home/dev/.local/share/applications/zcode-user.desktop", "[Desktop Entry]\nExec=/home/dev/app/zcode %U\n",
    ),
    (
      "/xdg1/applications/ZCode.desktop", "[Desktop Entry]\nExec=/opt/Zed/zcode\n",
    ),
  ])
  let out = zcode_desktop_candidates(
    env~,
    read_file=fn(p : String) -> String? { contents.get(p) },
    list_dir=fn(p : String) -> Array[String]? { files.get(p) },
  )
  assert_eq(out, [
    "/home/dev/app/zcode.cjs", "/home/dev/app/../resources/glm/zcode.cjs", "/home/dev/app/resources/glm/zcode.cjs",
    "/opt/Zed/zcode.cjs", "/opt/Zed/../resources/glm/zcode.cjs", "/opt/Zed/resources/glm/zcode.cjs",
  ])
}

///|
async test "desktop_candidates_degrade_and_skip" {
  // Home applications first (XDG precedence), then the default XDG dirs;
  // a failed listing or read degrades to a skip.
  let env = config_env_of([("HOME", "/home/dev")])
  let listed : Array[String] = []
  let out = zcode_desktop_candidates(
    env~,
    read_file=fn(_p : String) -> String? { None },
    list_dir=fn(p : String) -> Array[String]? {
      listed.push(p)
      None
    },
  )
  assert_eq(out, [])
  assert_eq(listed, [
    "/home/dev/.local/share/applications", "/usr/local/share/applications", "/usr/share/applications",
  ])
  let win = config_env_of([("OS", "Windows_NT")])
  assert_eq(
    zcode_desktop_candidates(
      env=win,
      read_file=fn(_p : String) -> String? { None },
      list_dir=fn(_p : String) -> Array[String]? { None },
    ),
    [],
  )
}

///|
async test "symlink_candidates_resolve_path_hits" {
  let env = config_env_of([("PATH", "/usr/local/bin:/opt/wrapper/bin")])
  let links : Map[String, String] = Map::from_array([
    ("/usr/local/bin/zcode", "/real/zcode/bin/zcode"),
  ])
  let out = zcode_symlink_candidates(env~, realpath=fn(p : String) -> String? {
    links.get(p)
  })
  assert_eq(out, [
    "/real/zcode/bin/zcode.cjs", "/real/zcode/bin/../resources/glm/zcode.cjs", "/real/zcode/bin/resources/glm/zcode.cjs",
  ])
  // A dangling PATH hit contributes nothing.
  let dangling = config_env_of([("PATH", "/gone/bin")])
  assert_eq(
    zcode_symlink_candidates(env=dangling, realpath=fn(_p : String) -> String? {
      None
    }),
    [],
  )
  // The tier is unix-only: windows-shaped envs skip it.
  let win = config_env_of([("OS", "Windows_NT"), ("PATH", "C:\\bin")])
  assert_eq(
    zcode_symlink_candidates(env=win, realpath=fn(_p : String) -> String? {
      Some("C:\\real\\zcode")
    }),
    [],
  )
}

///|
async test "probe_paths_merges_static_desktop_symlink_in_order" {
  let env = config_env_of([("PATH", "/bin"), ("HOME", "/home/dev")])
  let out = zcode_probe_paths(
    config=zcode_config(),
    env~,
    read_file=fn(p : String) -> String? {
      if p == "/usr/share/applications/zcode.desktop" {
        Some("Exec=/opt/Desk/zcode\n")
      } else {
        None
      }
    },
    list_dir=fn(p : String) -> Array[String]? {
      if p == "/usr/share/applications" {
        Some(["zcode.desktop"])
      } else {
        None
      }
    },
    realpath=fn(p : String) -> String? {
      if p == "/bin/zcode" {
        Some("/real/bin/zcode")
      } else {
        None
      }
    },
  )
  assert_eq(out, [
    "/bin/zcode", "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs", "/home/dev/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
    "/home/dev\\AppData\\Local\\Programs\\ZCode\\resources\\glm\\zcode.cjs", "/opt/ZCode/resources/glm/zcode.cjs",
    "/usr/share/zcode/resources/glm/zcode.cjs", "/opt/Desk/zcode.cjs", "/opt/Desk/../resources/glm/zcode.cjs",
    "/opt/Desk/resources/glm/zcode.cjs", "/real/bin/zcode.cjs", "/real/bin/../resources/glm/zcode.cjs",
    "/real/bin/resources/glm/zcode.cjs",
  ])
  // Trusted bins short-circuit every tier.
  let trusted = { ..zcode_config(), bin: Some("/opt/explicit/zcode"), }
  assert_eq(
    zcode_probe_paths(
      config=trusted,
      env~,
      read_file=fn(_p : String) -> String? { None },
      list_dir=fn(_p : String) -> Array[String]? { None },
      realpath=fn(_p : String) -> String? { None },
    ),
    [],
  )
}

///|
test "resolve_command_from_uses_given_candidates" {
  let env = config_env_of([])
  match
    zcode_resolve_command_from(
      config=zcode_config(),
      env~,
      candidates=["/nope/zcode", "/opt/Desk/zcode.cjs"],
      exists=config_exists_only(["/opt/Desk/zcode.cjs"]),
    ) {
    Ok((program, args)) => {
      assert_eq(program, "node")
      assert_eq(args.length(), 3)
      assert_eq(args[0], "/opt/Desk/zcode.cjs")
      assert_eq(args[1], "app-server")
      assert_eq(args[2], "--stdio")
    }
    Err(e) => fail(Show::to_string(e))
  }
  // A PATH-stub hit keeps the bare command even when later candidates exist.
  match
    zcode_resolve_command_from(
      config=zcode_config(),
      env~,
      candidates=["/usr/bin/zcode", "/opt/Desk/zcode.cjs"],
      exists=config_exists_only(["/usr/bin/zcode", "/opt/Desk/zcode.cjs"]),
    ) {
    Ok((program, _args)) => assert_eq(program, "zcode")
    Err(e) => fail(Show::to_string(e))
  }
  match
    zcode_resolve_command_from(
      config=zcode_config(),
      env~,
      candidates=["/usr/bin/zcode"],
      exists=config_exists_only([]),
    ) {
    Err(ZcodeBinNotFound) => ()
    Ok(_) => fail("expected ZcodeBinNotFound")
    Err(other) => fail(Show::to_string(other))
  }
}

///|
test "resolve_windows_shims_keep_probed_path" {
  match
    zcode_resolve_command(
      config=zcode_config(),
      env=config_env_of([("OS", "Windows_NT"), ("PATH", "C:\\tools")]),
      exists=config_exists_only(["C:\\tools\\zcode.cmd"]),
    ) {
    Ok((program, args)) => {
      assert_eq(program, "C:\\tools\\zcode.cmd")
      assert_eq(args[0], "app-server")
      assert_eq(args[1], "--stdio")
    }
    Err(e) => fail(Show::to_string(e))
  }
  match
    zcode_resolve_command(
      config=zcode_config(),
      env=config_env_of([("OS", "Windows_NT"), ("PATH", "C:\\tools")]),
      exists=config_exists_only(["C:\\tools\\zcode.exe"]),
    ) {
    Ok((program, _args)) => assert_eq(program, "C:\\tools\\zcode.exe")
    Err(e) => fail(Show::to_string(e))
  }
  // A plain windows PATH hit still keeps the bare name.
  match
    zcode_resolve_command(
      config=zcode_config(),
      env=config_env_of([("OS", "Windows_NT"), ("PATH", "C:\\tools")]),
      exists=config_exists_only(["C:\\tools\\zcode"]),
    ) {
    Ok((program, _args)) => assert_eq(program, "zcode")
    Err(e) => fail(Show::to_string(e))
  }
}

///|
test "resolve_js_entries_get_node_prefix" {
  for suffix in [".cjs", ".mjs", ".js"] {
    let config = {
      ..zcode_config(),
      bin: Some("/opt/zcode/bin/zcode" + suffix),
    }
    match
      zcode_resolve_command(
        config~,
        env=config_env_of([]),
        exists=config_exists_only([]),
      ) {
      Ok((program, args)) => {
        assert_eq(program, "node")
        assert_eq(args[0], "/opt/zcode/bin/zcode" + suffix)
      }
      Err(e) => fail(Show::to_string(e))
    }
  }
  assert_true(zcode_bin_is_js("/a/b.cjs"))
  assert_true(zcode_bin_is_js("/a/b.mjs"))
  assert_true(zcode_bin_is_js("/a/b.js"))
  assert_true(!zcode_bin_is_js("/a/b.exe"))
  assert_true(!zcode_bin_is_js("/a/zcode"))
}

///|
/// The real host env (injected here, not read globally) must still surface
/// the fixed bundle candidates.
test "real_env_lists_bundle_candidates" {
  let env = fn(key : String) -> String? { @env.get_env_var(key) }
  let candidates = zcode_candidate_paths(config=zcode_config(), env~)
  assert_true(
    candidates.contains(
      "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
    ),
  )
  assert_true(candidates.contains("/opt/ZCode/resources/glm/zcode.cjs"))
  assert_true(candidates.contains("/usr/share/zcode/resources/glm/zcode.cjs"))
}

///|
async test "detect_trusts_explicit_bin_without_probing" {
  let config = { ..zcode_config(), bin: Some("/usr/local/bin/zcode"), }
  let probes : Array[String] = []
  match
    zcode_ext_if_detected(config~, env=config_env_of([]), exists=fn(
      p : String,
    ) -> Bool {
      probes.push(p)
      false
    }) {
    Some(_) => assert_eq(probes, [])
    None => fail("expected detection via trusted config.bin")
  }
}

///|
async test "detect_probes_every_candidate_once_in_order" {
  let probes : Array[String] = []
  let present = config_exists_only(["/a/zcode"])
  let env = config_env_of([("PATH", "/a:/b")])
  match
    zcode_ext_if_detected(config=zcode_config(), env~, exists=fn(
      p : String,
    ) -> Bool {
      probes.push(p)
      present(p)
    }) {
    Some(_) =>
      assert_eq(probes, [
        "/a/zcode", "/b/zcode", "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
        "/opt/ZCode/resources/glm/zcode.cjs", "/usr/share/zcode/resources/glm/zcode.cjs",
      ])
    None => fail("expected detection via first PATH candidate")
  }
}

///|
async test "detect_finds_later_bundle_candidate" {
  let probes : Array[String] = []
  let bundle = "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"
  let present = config_exists_only([bundle])
  let env = config_env_of([("PATH", "/bin")])
  match
    zcode_ext_if_detected(config=zcode_config(), env~, exists=fn(
      p : String,
    ) -> Bool {
      probes.push(p)
      present(p)
    }) {
    Some(_) =>
      assert_eq(probes, [
        "/bin/zcode", "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
        "/opt/ZCode/resources/glm/zcode.cjs", "/usr/share/zcode/resources/glm/zcode.cjs",
      ])
    None => fail("expected detection via bundle candidate")
  }
}

///|
async test "detect_raising_probe_degrades_to_miss" {
  let probes : Array[String] = []
  let env = config_env_of([("PATH", "/bin")])
  match
    zcode_ext_if_detected(config=zcode_config(), env~, exists=fn(
      p : String,
    ) -> Bool raise {
      probes.push(p)
      fail("probe boom")
    }) {
    Some(_) => fail("expected no detection when every probe raises")
    None =>
      assert_eq(probes, [
        "/bin/zcode", "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
        "/opt/ZCode/resources/glm/zcode.cjs", "/usr/share/zcode/resources/glm/zcode.cjs",
      ])
  }
}

///|
async test "detect_all_miss_returns_none" {
  match
    zcode_ext_if_detected(config=zcode_config(), env=config_env_of([]), exists=fn(
      _p : String,
    ) -> Bool {
      false
    }) {
    Some(_) => fail("expected None when nothing is found")
    None => ()
  }
}
