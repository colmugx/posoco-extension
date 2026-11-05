///|
/// Home resolution is internal to MBTX: no devkit or status event dependency.
test "MBTX home resolution prefers Unix HOME only on Unix" {
  assert_eq(
    mbtx_home_from_env(
      windows=false,
      home=Some(" /home/guest "),
      userprofile=Some("C:/Users/ignored"),
      homedrive=None,
      homepath=None,
    ),
    Some("/home/guest"),
  )
  assert_eq(
    mbtx_home_from_env(
      windows=false,
      home=Some(" "),
      userprofile=Some("C:/Users/ignored"),
      homedrive=None,
      homepath=None,
    ),
    None,
  )
}

///|
test "MBTX home resolution uses native Windows home variables" {
  assert_eq(
    mbtx_home_from_env(
      windows=true,
      home=Some("/c/Users/ignored"),
      userprofile=Some(" C:/Users/guest "),
      homedrive=Some("D:"),
      homepath=Some("/Users/fallback"),
    ),
    Some("C:/Users/guest"),
  )
  assert_eq(
    mbtx_home_from_env(
      windows=true,
      home=Some("/home/ignored"),
      userprofile=Some(" "),
      homedrive=Some("D:"),
      homepath=Some("/Users/fallback"),
    ),
    Some("D:/Users/fallback"),
  )
  assert_eq(
    mbtx_home_from_env(
      windows=true,
      home=Some("/home/ignored"),
      userprofile=None,
      homedrive=Some("D:"),
      homepath=None,
    ),
    None,
  )
}
