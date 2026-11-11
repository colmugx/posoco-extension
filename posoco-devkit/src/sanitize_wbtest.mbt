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

///|
test "is_control classifies by general category, not by hand-written ranges" {
  for ch in ['\u{0000}', '\u{001B}', '\u{007F}', '\u{0085}', '\t', '\n'] {
    assert_true(is_control(ch))
  }
  // Format characters: bidi controls, zero-width space, soft hyphen, BOM, tag.
  for
    ch in [
      '\u{00AD}', '\u{061C}', '\u{200B}', '\u{200E}', '\u{202E}', '\u{2066}', '\u{FEFF}',
      '\u{FFF9}', '\u{E0020}', '\u{E007F}',
    ] {
    assert_true(is_control(ch))
  }
  assert_true(is_control('\u{2028}'))
  assert_true(is_control('\u{2029}'))
  // Lone surrogate.
  assert_true(is_control((0xD800).unsafe_to_char()))
  // Separators that are not controls, and the variation selector, which is Mn:
  // strip it and emoji lose their presentation.
  for
    ch in [
      '\u{00A0}', '\u{3000}', '\u{2003}', '\u{FE0F}', 'A', '\u{4E2D}', '🙂',
    ] {
    assert_false(is_control(ch))
  }
}

///|
test "display_strip keeps line structure and joins, drops invisible controls" {
  assert_eq(display_strip("a\tb\nc"), "a\tb\nc")
  // ZWJ emoji and Persian ZWNJ survive: stripping them would break the cluster.
  assert_eq(
    display_strip("👨\u{200D}👩\u{200D}👧"),
    "👨\u{200D}👩\u{200D}👧",
  )
  assert_eq(display_strip("می\u{200C}خواهم"), "می\u{200C}خواهم")
  assert_eq(display_strip("❤\u{FE0F}"), "❤\u{FE0F}")
  assert_eq(display_strip("hello\u{0000}\u{001B} world\r\n"), "hello world\n")
  for
    ch in [
      '\u{00AD}', '\u{200B}', '\u{200E}', '\u{202E}', '\u{2066}', '\u{2028}', '\u{2029}',
      '\u{FEFF}', '\u{009C}',
    ] {
    assert_eq(display_strip("left\{ch}right"), "leftright")
  }
  assert_eq(
    display_strip(" \u{00A0}\u{3000}~界🙂"),
    " \u{00A0}\u{3000}~界🙂",
  )
}

///|
test "display_strip flattens subdivision-flag tag sequences" {
  // U+1F3F4 + tag letters gbsct + U+E007F is the Scotland flag. Tag characters
  // are Cf, so the sequence degrades to the base glyph by design.
  assert_eq(display_strip("🏴\u{E0067}\u{E0062}\u{E007F}"), "🏴")
}

///|
test "display_label replaces every control and stays single-line" {
  assert_eq(display_label("a\tb\nc\rd"), "a b c d")
  assert_eq(display_label("pr\u{001B}[2Jeof"), "pr [2Jeof")
  assert_eq(display_label("👨\u{200D}👩"), "👨 👩")
  assert_eq(display_label("界\u{202E}esrever"), "界 esrever")
  assert_eq(display_label("a\u{0000}b", replacement='_'), "a_b")
  // Nothing to replace: the same string comes back without a rebuild.
  assert_eq(display_label("/repo/src/main.mbt"), "/repo/src/main.mbt")
}
