///|
/// session_cwd_test.mbt — native tests for the recorded project directory
/// (`cetas.cwd`) and the bucket-name helpers that back the `/sessions` "All"
/// view.

///|
test "bucket helpers: root, prefix, slug recovery" {
  assert_eq(
    @posoco-ext-fs-session.project_sessions_root("/home/u"),
    "/home/u/.cetas/sessions",
  )
  assert_eq(
    @posoco-ext-fs-session.project_sessions_dir("/home/u", "/a/b_c"),
    "/home/u/.cetas/sessions/session_b_c_df04c2002ded",
  )
  assert_true(
    @posoco-ext-fs-session.is_project_dir_name("session_x_0123456789ab"),
  )
  // A directory that merely looks session-ish but has no fingerprint still
  // yields its whole remainder, never an error.
  assert_true(@posoco-ext-fs-session.is_project_dir_name("session_notes"))
  assert_false(
    @posoco-ext-fs-session.is_project_dir_name("other_x_0123456789ab"),
  )
  assert_eq(
    @posoco-ext-fs-session.bucket_slug("session_b_c_df04c2002ded"),
    "b_c",
  )
  assert_eq(
    @posoco-ext-fs-session.bucket_slug("session_project_8a5edab28263"),
    "project",
  )
  // Names that do not carry the layout shape come back unchanged.
  assert_eq(@posoco-ext-fs-session.bucket_slug("session_notes"), "notes")
  assert_eq(
    @posoco-ext-fs-session.bucket_slug("session_x_notafingerprint"),
    "x_notafingerprint",
  )
}

///|
test "metadata_with_cwd stamps, preserves, and ignores the absent case" {
  let bare : Map[String, Json] = Map::from_array([])
  let stamped = @posoco-ext-fs-session.metadata_with_cwd(bare, Some("/a/b_c"))
  assert_eq(
    stamped.get(@posoco-ext-fs-session.SESSION_CWD_METADATA_KEY),
    Some(Json::string("/a/b_c")),
  )
  assert_eq(
    @posoco-ext-fs-session.session_cwd_from_metadata(stamped),
    Some("/a/b_c"),
  )
  // A store with no project binding never decorates metadata.
  let untouched = @posoco-ext-fs-session.metadata_with_cwd(bare, None)
  assert_eq(untouched.keys().to_array(), [])
  // An empty cwd is the same as no binding.
  let empty = @posoco-ext-fs-session.metadata_with_cwd(bare, Some(""))
  assert_eq(empty.keys().to_array(), [])
  // Unrelated metadata survives; a wrong recorded cwd is replaced.
  let foreign : Map[String, Json] = Map::from_array([
    ("posoco.title", Json::string("Fix login")),
    (@posoco-ext-fs-session.SESSION_CWD_METADATA_KEY, Json::string("/stale")),
  ])
  let fixed = @posoco-ext-fs-session.metadata_with_cwd(foreign, Some("/a/b_c"))
  assert_eq(fixed.get("posoco.title"), Some(Json::string("Fix login")))
  assert_eq(
    @posoco-ext-fs-session.session_cwd_from_metadata(fixed),
    Some("/a/b_c"),
  )
}

///|
test "session_cwd_from_metadata ignores non-string and empty payloads" {
  let malformed : Map[String, Json] = Map::from_array([
    (@posoco-ext-fs-session.SESSION_CWD_METADATA_KEY, Json::number(3.0)),
  ])
  assert_eq(@posoco-ext-fs-session.session_cwd_from_metadata(malformed), None)
  let blank : Map[String, Json] = Map::from_array([
    (@posoco-ext-fs-session.SESSION_CWD_METADATA_KEY, Json::string("")),
  ])
  assert_eq(@posoco-ext-fs-session.session_cwd_from_metadata(blank), None)
  let missing : Map[String, Json] = Map::from_array([])
  assert_eq(@posoco-ext-fs-session.session_cwd_from_metadata(missing), None)
}

///|
async test "io[native]: of_project persists the cwd and summary reads it back" {
  let home = fresh_root("cwd-record")
  let store = @posoco-ext-fs-session.JsonlSessionStore::of_project(
    home~,
    cwd="/a/b_c",
  )
  let session = @posoco.Session::{
    messages: [
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")]),
    ],
    metadata: Map::from_array([
      ("posoco.title", Json::string("Project session")),
    ]),
  }
  store.save("sess_cwd", session) catch {
    e => fail("save failed: \{e}")
  }
  let raw = @xfs.read_file_to_string(
    home + "/.cetas/sessions/session_b_c_df04c2002ded/sess_cwd.jsonl",
  ) catch {
    _ => fail("read back failed")
  }
  let first_line = raw.split("\n").next().unwrap_or("")
  assert_true(first_line.contains("\"cetas.cwd\":\"/a/b_c\""))
  // The title metadata the agent wrote is preserved next to the cwd.
  assert_true(first_line.contains("Project session"))
  let summary = store.summary("sess_cwd") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(summary.cwd, Some("/a/b_c"))
  assert_eq(@posoco-ext-fs-session.display_title(summary), "Project session")
  @fs.rmdir(home, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: appending the first message records the cwd too" {
  let home = fresh_root("cwd-append")
  let store = @posoco-ext-fs-session.JsonlSessionStore::of_project(
    home~,
    cwd="/x/y/",
  )
  store.append_messages("sess_append", 0, [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("first")]),
  ]) catch {
    e => fail("append failed: \{e}")
  }
  let summary = store.summary("sess_append") catch {
    e => fail("summary failed: \{e}")
  }
  // Trailing separators normalize before hashing and before recording.
  assert_eq(summary.cwd, Some("/x/y"))
  @fs.rmdir(home, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: a legacy journal keeps cwd absent instead of guessing" {
  let root = fresh_root("cwd-legacy")
  let legacy = "{}\n" +
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"legacy turn\"}]}\n"
  @xfs.write_string_to_file(root + "/sess_legacy.jsonl", legacy) catch {
    _ => fail("write failed")
  }
  let store = @posoco-ext-fs-session.JsonlSessionStore(root)
  let summary = store.summary("sess_legacy") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(summary.cwd, None)
  // Legacy titles still come from the first user message.
  assert_eq(@posoco-ext-fs-session.display_title(summary), "legacy turn")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: a store without a project binding writes no cwd" {
  let root = fresh_root("cwd-unbound")
  let store = @posoco-ext-fs-session.JsonlSessionStore(root)
  store.save("sess_unbound", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("save failed: \{e}")
  }
  let summary = store.summary("sess_unbound") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(summary.cwd, None)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}
