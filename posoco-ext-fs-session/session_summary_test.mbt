///|
/// session_summary_test.mbt — native tests for session summaries and titles.

///|
fn sixty_char_text() -> String {
  "012345678901234567890123456789012345678901234567890123456789"
}

///|
async test "io[native]: explicit name wins over automatic title" {
  let root = fresh_root("summary-named")
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_named", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([
      ("name", Json::string("Weekly Review")),
      (
        @posoco.SESSION_TITLE_METADATA_KEY,
        Json::string("automatic title should not win"),
      ),
    ]),
  }) catch {
    e => fail("seed named session failed: \{e}")
  }
  let s = store.summary("sess_named") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(s.id, "sess_named")
  assert_eq(s.name, Some("Weekly Review"))
  assert_eq(s.title, Some("automatic title should not win"))
  assert_eq(@posoco-ext-fs-session.display_title(s), "Weekly Review")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: automatic title comes from session metadata" {
  let root = fresh_root("summary-title")
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_title", @posoco.Session::{
    messages: [
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("injected memory must not become the title"),
      ]),
    ],
    metadata: Map::from_array([
      (
        @posoco.SESSION_TITLE_METADATA_KEY,
        Json::string("  investigate   the login\n race condition  "),
      ),
    ]),
  }) catch {
    e => fail("seed titled session failed: \{e}")
  }
  let s = store.summary("sess_title") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(s.name, None)
  assert_eq(s.title, Some("investigate the login race condition"))
  assert_eq(
    @posoco-ext-fs-session.display_title(s),
    "investigate the login race condition",
  )
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: automatic title truncates at 50 chars" {
  let root = fresh_root("summary-title-truncated")
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_title_truncated", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([
      (@posoco.SESSION_TITLE_METADATA_KEY, Json::string(sixty_char_text())),
    ]),
  }) catch {
    e => fail("seed titled session failed: \{e}")
  }
  let s = store.summary("sess_title_truncated") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(
    s.title,
    Some("01234567890123456789012345678901234567890123456789"),
  )
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: legacy session falls back to first user-role message" {
  let root = fresh_root("summary-legacy")
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_legacy", @posoco.Session::{
    messages: [
      @posoco.Message::SystemMessage(content=[
        @posoco.Content::Text("system preamble is not a title"),
      ]),
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("  old   session\n title  "),
      ]),
    ],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("seed legacy session failed: \{e}")
  }
  let s = store.summary("sess_legacy") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(s.title, Some("old session title"))
  assert_eq(@posoco-ext-fs-session.display_title(s), "old session title")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: display_title falls back to the session id" {
  let root = fresh_root("summary-empty")
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_silent", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("seed empty session failed: \{e}")
  }
  let s = store.summary("sess_silent") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(s.name, None)
  assert_eq(s.title, None)
  assert_eq(@posoco-ext-fs-session.display_title(s), "sess_silent")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: summary of a missing file is empty" {
  let root = fresh_root("summary-missing")
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  let s = store.summary("ghost") catch {
    e => fail("summary of missing session failed: \{e}")
  }
  assert_eq(s.name, None)
  assert_eq(s.title, None)
  assert_eq(@posoco-ext-fs-session.display_title(s), "ghost")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
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
test "display_title cuts metadata title at char boundaries, not bytes" {
  let s : @posoco-ext-fs-session.SessionSummary = {
    id: "sess_cjk",
    name: None,
    title: Some(repeat_decade(6)),
  }
  assert_eq(@posoco-ext-fs-session.display_title(s), repeat_decade(6))
}
