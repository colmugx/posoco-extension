///|
/// session_summary_test.mbt — native tests for session summaries and titles.

///|
fn sixty_char_text() -> String {
  "012345678901234567890123456789012345678901234567890123456789"
}

///|
async test "io[native]: summary picks the metadata name for the title" {
  let root = fresh_root("summary-named")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_named", @posoco.Session::{
    messages: [
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text(sixty_char_text()),
      ]),
    ],
    metadata: Map::from_array([("name", Json::string("Weekly Review"))]),
  }) catch {
    e => fail("seed named session failed: \{e}")
  }
  let s = store.summary("sess_named") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(s.id, "sess_named")
  assert_eq(s.name, Some("Weekly Review"))
  assert_eq(display_title(s), "Weekly Review")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: display_title truncates first user text at 50 chars" {
  let root = fresh_root("summary-unnamed")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_unnamed", @posoco.Session::{
    messages: [
      // System messages and assistant replies never become the title.
      @posoco.Message::SystemMessage(content=[
        @posoco.Content::Text("system preamble is not a title"),
      ]),
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text(sixty_char_text()),
      ]),
    ],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("seed unnamed session failed: \{e}")
  }
  let s = store.summary("sess_unnamed") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(s.name, None)
  assert_eq(s.first_user_text, sixty_char_text())
  assert_eq(
    display_title(s),
    "01234567890123456789012345678901234567890123456789",
  )
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: display_title falls back to the session id" {
  let root = fresh_root("summary-empty")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_silent", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("seed empty session failed: \{e}")
  }
  let s = store.summary("sess_silent") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(display_title(s), "sess_silent")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: summary of a missing file is empty" {
  let root = fresh_root("summary-missing")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  let s = store.summary("ghost") catch {
    e => fail("summary of missing session failed: \{e}")
  }
  assert_eq(s.name, None)
  assert_eq(s.first_user_text, "")
  assert_eq(display_title(s), "ghost")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
test "display_title collapses whitespace before truncating" {
  let s : SessionSummary = {
    id: "sess_ws",
    name: None,
    first_user_text: "  fix the \n\t parser  crash   reported downstream  ",
  }
  assert_eq(display_title(s), "fix the parser crash reported downstream")
}

///|
fn repeat_decade(times : Int) -> String {
  let decade = "甲乙丙丁戊己庚辛壬癸"
  let buf = StringBuilder()
  let mut i = 0
  while i < times {
    buf.write_string(decade)
    i += 1
  }
  buf.to_string()
}

///|
test "display_title cuts at char boundaries, not bytes" {
  let s : SessionSummary = {
    id: "sess_cjk",
    name: None,
    first_user_text: repeat_decade(6),
  }
  assert_eq(display_title(s), repeat_decade(5))
}
