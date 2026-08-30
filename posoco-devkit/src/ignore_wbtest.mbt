///|
test "matches_ignore_covers_exact_prefix_and_nested_segments" {
  let patterns = ["node_modules", "_build"]
  assert_true(matches_ignore("node_modules", patterns))
  assert_true(matches_ignore("node_modules/foo.js", patterns))
  assert_true(matches_ignore("src/node_modules/x", patterns))
  assert_true(matches_ignore("sub/_build/out.mbt", patterns))
  assert_false(matches_ignore("src/main.mbt", patterns))
  assert_false(matches_ignore("node_modules_backup", patterns))
}

///|
test "has_hidden_segment_checks_each_segment" {
  assert_true(has_hidden_segment(".git/HEAD"))
  assert_true(has_hidden_segment("src/.hidden/x"))
  assert_false(has_hidden_segment("src/main.mbt"))
  assert_false(has_hidden_segment(""))
}

///|
test "glob_match_supports_star_and_doublestar" {
  assert_true(glob_match("*.mbt", "a.mbt"))
  assert_true(glob_match("**/*.mbt", "a.mbt"))
  assert_true(glob_match("**/*.mbt", "src/deep/a.mbt"))
  assert_true(glob_match("src/*.mbt", "src/a.mbt"))
  assert_true(glob_match("**", "anything/at/all"))
  assert_false(glob_match("*.mbt", "src/a.mbt"))
  assert_false(glob_match("src/*.mbt", "src/deep/a.mbt"))
  assert_true(glob_match("foo*", "foobar"))
  assert_false(glob_match("foo*", "bar/foo"))
}
