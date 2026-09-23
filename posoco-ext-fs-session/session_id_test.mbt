///|
test "session id accepts opaque filename stems" {
  assert_eq(
    @posoco-ext-fs-session.validate_session_id("session-01_alpha"),
    Ok(()),
  )
}

///|
test "session id rejects empty and relative segments" {
  assert_true(@posoco-ext-fs-session.validate_session_id("") is Err(_))
  assert_true(@posoco-ext-fs-session.validate_session_id(".") is Err(_))
  assert_true(@posoco-ext-fs-session.validate_session_id("..") is Err(_))
}

///|
test "session id rejects native and windows separators" {
  assert_true(@posoco-ext-fs-session.validate_session_id("../escape") is Err(_))
  assert_true(
    @posoco-ext-fs-session.validate_session_id("nested/session") is Err(_),
  )
  assert_true(
    @posoco-ext-fs-session.validate_session_id("nested\\session") is Err(_),
  )
}

///|
test "jsonl store contributes exactly one session port" {
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    "sessions",
  )
  let manifest = store.manifest()
  assert_eq(manifest.id, "posoco_ext_fs_session")
  assert_eq(manifest.sessions.length(), 1)
}
