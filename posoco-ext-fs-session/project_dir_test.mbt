///|
/// project_dir_test.mbt — native tests for project bucket naming.

///|
test "project_dir_name keeps /a/b_c and /a/b/c in different buckets" {
  // The dash-era collision case: slugging the basename alone maps both to
  // the same bucket; the cwd fingerprint must separate them.
  let underscore = project_dir_name("/a/b_c")
  let nested = project_dir_name("/a/b/c")
  assert_true(underscore != nested)
}

///|
test "project_dir_name golden vectors" {
  assert_eq(project_dir_name("/a/b_c"), "session_b_c_df04c2002ded")
  assert_eq(project_dir_name("/a/b/c"), "session_c_42146b29e39f")
  assert_eq(project_dir_name("/x/y"), "session_y_62b0ea75ac86")
  // Root cwd: no basename, generic slug, fingerprint of "/".
  assert_eq(project_dir_name("/"), "session_project_8a5edab28263")
  // Windows separators normalize before hashing.
  assert_eq(
    project_dir_name("C:\\Users\\colin\\demo"),
    "session_demo_ac30b4732a24",
  )
}

///|
test "normalize_cwd drops trailing separators and keeps the root" {
  assert_eq(normalize_cwd("/x/y/"), "/x/y")
  assert_eq(normalize_cwd("/x/y//"), "/x/y")
  assert_eq(normalize_cwd("C:\\Users\\colin\\demo\\"), "C:/Users/colin/demo")
  assert_eq(normalize_cwd("/"), "/")
  assert_eq(project_dir_name("/x/y/"), project_dir_name("/x/y"))
}

///|
test "project_slug keeps safe chars and replaces the rest" {
  assert_eq(project_slug("my_project.v2-beta"), "my_project.v2-beta")
  assert_eq(project_slug(""), "project")
  assert_eq(project_slug("   "), "project")
  assert_eq(project_slug("我的 项目"), "project")
  // CJK and spaces map to '-' inside an otherwise usable basename.
  assert_eq(project_slug("我的proj"), "--proj")
  assert_eq(
    project_slug("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"),
    "abcdefghijklmnopqrstuvwxyzabcdefghijklmn",
  )
}

///|
async test "io[native]: of_project stores into the project bucket" {
  let home = fresh_root("of-project")
  let store = JsonlSessionStore::of_project(home~, cwd="/a/b_c")
  let session = @posoco.Session::{
    messages: [
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("hi from project b_c"),
      ]),
    ],
    metadata: Map::from_array([]),
  }
  store.save("sess_p", session) catch {
    e => fail("save via of_project failed: \{e}")
  }
  let bucket = home + "/.cetas/sessions/session_b_c_df04c2002ded"
  assert_true(@xfs.path_exists(bucket + "/sess_p.jsonl"))
  // A sibling project whose basename slugs differently must not see the
  // first project's sessions.
  let other = JsonlSessionStore::of_project(home~, cwd="/a/b/c")
  let ids = other.list_ids() catch {
    e => fail("list_ids on sibling bucket failed: \{e}")
  }
  assert_eq(ids, [])
  @fs.rmdir(home, recursive=true) catch {
    _ => ()
  }
}
