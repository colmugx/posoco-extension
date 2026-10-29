///|
/// The RUI bridge must keep serving the Instrument palette: a swapped component
/// that silently falls back to Nova's near-black primary would break the one
/// visual identity the Board has.
test "rui tokens map onto instrument variables" {
  let tokens = instrument_tokens
  assert_true(tokens.contains("--rui-primary: var(--accent)"))
  assert_true(tokens.contains("--rui-background: var(--canvas)"))
  assert_true(tokens.contains("--rui-foreground: var(--ink)"))
  assert_true(tokens.contains("--rui-border: var(--line)"))
  assert_true(tokens.contains("--rui-destructive: var(--danger)"))
  // RUI defaults to Inter; the shell is read mostly as CJK board titles.
  assert_eq(tokens[tokens.length() - 1], "font-family: var(--font-sans)")
}

///|
/// A token list without the font override would silently change every glyph on
/// the board, so the override is asserted structurally, not just by value.
test "font override stays last so it wins over the RUI root recipe" {
  let mut font_family_at = -1
  for index, token in instrument_tokens {
    if token.has_prefix("font-family:") {
      font_family_at = index
    }
  }
  assert_eq(font_family_at, instrument_tokens.length() - 1)
}
