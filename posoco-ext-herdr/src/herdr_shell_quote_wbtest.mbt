///|
/// Native-only like `herdr_native.mbt`, where `herdr_shell_quote` lives.
test "shell quoting wraps args and escapes single quotes" {
  inspect(herdr_shell_quote("plain"), content="'plain'")
  inspect(herdr_shell_quote("it's"), content="'it'\\''s'")
  inspect(herdr_shell_quote(""), content="''")
}
