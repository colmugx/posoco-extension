///|
test "companion_path puts a file beside the JSONL history" {
  inspect(
    companion_path("/cetas-home/.cetas/sessions", "cetas-1"),
    content="/cetas-home/.cetas/sessions/cetas-1.host.json",
  )
}

///|
test "companion_path accepts a custom extension" {
  inspect(
    companion_path("/root", "cetas-2", ext="wire.jsonl"),
    content="/root/cetas-2.wire.jsonl",
  )
}

///|
test "companion_path mirrors jsonl_session_path's directory and stem" {
  let root = "/cetas-home/.cetas/sessions"
  let jsonl = jsonl_session_path(root, "cetas-3")
  let companion = companion_path(root, "cetas-3")
  inspect(
    companion[:companion.length() - ".host.json".length()].to_owned(),
    content=jsonl[:jsonl.length() - ".jsonl".length()].to_owned(),
  )
}

///|
test "companion_path callers can gate ids with validate_session_id" {
  // The escape guard stays at the caller boundary, same rule as the store.
  match validate_session_id("..") {
    Err(reason) =>
      assert_true(reason == "session id must not be a relative path segment")
    Ok(_) => fail("'..' must be rejected")
  }
  match validate_session_id("a/b") {
    Err(reason) =>
      assert_true(reason == "session id must not contain path separators")
    Ok(_) => fail("'a/b' must be rejected")
  }
  assert_true(validate_session_id("cetas-4") is Ok(_))
}
