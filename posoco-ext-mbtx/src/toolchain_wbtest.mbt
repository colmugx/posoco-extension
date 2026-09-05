///|
/// toolchain_wbtest.mbt — the pure path logic runs on injected inputs only;
/// the probing tests build real (fake-binary) toolchain directories under
/// the system temp dir and exercise the native edge + cache.

///|
test "candidates order override then PATH entries then home" {
  let empty : Array[String] = []
  assert_eq(
    toolchain_candidates(
      bin_override=Some("/opt/mbtx-bin"),
      path_env=Some("/usr/bin:/usr/local/bin"),
      home_dir=Some("/home/u"),
    ),
    ["/opt/mbtx-bin", "/usr/bin", "/usr/local/bin", "/home/u/.moon/bin"],
  )
  assert_eq(toolchain_candidates(), empty)
}

///|
test "candidates skip empty override and empty PATH entries" {
  assert_eq(
    toolchain_candidates(
      bin_override=Some(""),
      path_env=Some(":/a::/b"),
      home_dir=None,
    ),
    ["/a", "/b"],
  )
}

///|
test "resolve maps the first candidate onto both binaries" {
  match
    resolve_toolchain(
      bin_override=None,
      path_env=Some("/a:/b"),
      home_dir=Some("/h"),
    ) {
    Some(tc) => {
      assert_eq(tc.bin_dir, "/a")
      assert_eq(tc.moon, "/a/moon")
      assert_eq(tc.moonrun, "/a/moonrun")
    }
    None => fail("expected the first PATH candidate to resolve")
  }
  match resolve_toolchain() {
    None => ()
    Some(_) => fail("expected no resolution with nothing configured")
  }
}

///|
/// Write fake `moon`/`moonrun` executables into a fresh temp dir.
async fn mbtx_fake_toolchain(names : Array[String]) -> String {
  let dir = @fs.tmpdir(prefix="mbtx-test")
  for name in names {
    @fs.write_file(
      "\{dir}/\{name}",
      "#!/bin/sh\nexit 0\n",
      create_mode=CreateOrTruncate,
      permission=0o755,
    )
  }
  dir
}

///|
async test "ensure resolves override dir with both binaries and caches it" {
  let dir = mbtx_fake_toolchain(["moon", "moonrun"])
  let tools = MbtxTools(toolchain_bin=Some(dir))
  let tc = tools.ensure_toolchain_from(
    path_env=Some(""),
    home_dir=Some("/nonexistent-mbtx-home"),
  )
  assert_eq(tc.bin_dir, dir)
  assert_eq(tc.moon, "\{dir}/moon")
  assert_eq(tc.moonrun, "\{dir}/moonrun")
  match tools.resolved {
    Some(cached) => assert_eq(cached, dir)
    None => fail("expected the resolved bin_dir to be cached")
  }
}

///|
async test "ensure walks past candidates missing moonrun" {
  let partial = mbtx_fake_toolchain(["moon"])
  let full = mbtx_fake_toolchain(["moon", "moonrun"])
  let tools = MbtxTools()
  let tc = tools.ensure_toolchain_from(
    path_env=Some("\{partial}:\{full}"),
    home_dir=None,
  )
  assert_eq(tc.bin_dir, full)
}

///|
async test "ensure raises typed failure when nothing is usable" {
  let tools = MbtxTools()
  let result = Ok(
    tools.ensure_toolchain_from(
      path_env=Some(""),
      home_dir=Some("/nonexistent-mbtx-home"),
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::InvocationFailed(msg)) => {
      assert_true(msg.contains("no MoonBit toolchain found"))
      assert_true(msg.contains("~/.moon/bin"))
    }
    _ => fail("expected InvocationFailed for a missing toolchain")
  }
}
