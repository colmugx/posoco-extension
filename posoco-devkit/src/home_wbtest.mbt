///|
test "windows: USERPROFILE wins even when a Git-Bash HOME is set" {
  match
    home_dir_from_env(
      windows=true,
      home=Some("/c/Users/x"),
      userprofile=Some("C:\\Users\\x"),
      homedrive=None,
      homepath=None,
    ) {
    Some(home) => inspect(home, content="C:\\Users\\x")
    None => fail("USERPROFILE must win over HOME on Windows")
  }
}

///|
test "windows: HOMEDRIVE + HOMEPATH concatenates when USERPROFILE is unset" {
  match
    home_dir_from_env(
      windows=true,
      home=None,
      userprofile=None,
      homedrive=Some("C:"),
      homepath=Some("\\Users\\x"),
    ) {
    Some(home) => inspect(home, content="C:\\Users\\x")
    None => fail("HOMEDRIVE+HOMEPATH must resolve a Windows home")
  }
}

///|
test "windows: a HOME-only environment resolves to None" {
  match
    home_dir_from_env(
      windows=true,
      home=Some("/home/x"),
      userprofile=None,
      homedrive=None,
      homepath=None,
    ) {
    Some(_) => fail("HOME alone must not resolve a Windows home")
    None => ()
  }
}

///|
test "windows: whitespace-only values count as unset" {
  match
    home_dir_from_env(
      windows=true,
      home=None,
      userprofile=Some("  "),
      homedrive=Some("C:"),
      homepath=Some("\\Users\\x"),
    ) {
    Some(home) => inspect(home, content="C:\\Users\\x")
    None => fail("blank USERPROFILE must fall through to HOMEDRIVE+HOMEPATH")
  }
}

///|
test "windows: values are trimmed" {
  match
    home_dir_from_env(
      windows=true,
      home=None,
      userprofile=Some("  C:\\Users\\x  "),
      homedrive=None,
      homepath=None,
    ) {
    Some(home) => inspect(home, content="C:\\Users\\x")
    None => fail("USERPROFILE must be usable after trimming")
  }
}

///|
test "unix: HOME resolves and USERPROFILE is ignored" {
  match
    home_dir_from_env(
      windows=false,
      home=Some("/users/x"),
      userprofile=Some("C:\\Users\\x"),
      homedrive=None,
      homepath=None,
    ) {
    Some(home) => inspect(home, content="/users/x")
    None => fail("HOME must resolve a Unix home")
  }
}

///|
test "unix: no HOME means None even with Windows vars present" {
  match
    home_dir_from_env(
      windows=false,
      home=None,
      userprofile=Some("C:\\Users\\x"),
      homedrive=Some("C:"),
      homepath=Some("\\Users\\x"),
    ) {
    Some(_) => fail("Windows vars must not resolve a Unix home")
    None => ()
  }
}

///|
test "home_dir resolves on the host platform" {
  match home_dir() {
    Some(home) => assert_true(home != "")
    None => fail("the host environment must provide a home directory")
  }
}
