///|
/// Whitebox tests for the status protocol's color vocabulary. The op
/// publication itself is pinned by `events_system_wbtest.mbt`.

///|
test "color role vocabulary is closed and exact" {
  assert_eq(status_color_roles(), [
    "accent", "warning", "error", "success", "info", "muted",
  ])
  for role in status_color_roles() {
    assert_true(is_status_color_role(role))
  }
  assert_false(is_status_color_role("sparkly"))
  assert_false(is_status_color_role(""))
  assert_false(is_status_color_role("ACCENT"))
}
