///|
/// Tests for the diagnostics sanitizers shared by MCP/tool error messages.

///|
test "sanitize_path keeps plain paths unchanged" {
  inspect(sanitize_path("/repo/src/main.mbt"), content="/repo/src/main.mbt")
}

///|
test "sanitize_path flattens whitespace controls to single line" {
  inspect(sanitize_path("a\tb\nc\rd"), content="a b c d")
}

///|
test "sanitize_path strips escape and other control characters" {
  // ESC (0x1b) and DEL (0x7f) must not survive into terminal-facing text.
  inspect(sanitize_path("pr\u001b[2Jeof"), content="pr [2Jeof")
  inspect(sanitize_path("del\u007fete"), content="del ete")
  inspect(sanitize_path("nul\u0000byte"), content="nul byte")
}

///|
test "sanitize_path truncates with ellipsis beyond the limit" {
  inspect(sanitize_path("abcdefghij", limit=4), content="abcd...")
  // Exactly at the limit: no ellipsis.
  inspect(sanitize_path("abcd", limit=4), content="abcd")
  inspect(sanitize_path("", limit=4), content="")
}

///|
test "sanitize_label uses the shorter default and delegates" {
  let long = "x".repeat(130)
  let out = sanitize_label(long)
  assert_eq(out.length(), 123)
  assert_true(out.has_suffix("..."))
  inspect(sanitize_label("mcp-server", limit=4), content="mcp-...")
}
