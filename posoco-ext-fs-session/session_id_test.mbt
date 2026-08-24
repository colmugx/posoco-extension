///|
test "session id accepts opaque filename stems" {
  assert_eq(validate_session_id("session-01_alpha"), Ok(()))
}

///|
test "session id rejects empty and relative segments" {
  assert_true(validate_session_id("") is Err(_))
  assert_true(validate_session_id(".") is Err(_))
  assert_true(validate_session_id("..") is Err(_))
}

///|
test "session id rejects native and windows separators" {
  assert_true(validate_session_id("../escape") is Err(_))
  assert_true(validate_session_id("nested/session") is Err(_))
  assert_true(validate_session_id("nested\\session") is Err(_))
}

///|
test "jsonl store contributes exactly one session port" {
  let store = JsonlSessionStore::JsonlSessionStore("sessions")
  let manifest = store.manifest()
  assert_eq(manifest.id, "posoco_ext_fs_session")
  assert_eq(manifest.sessions.length(), 1)
}
