///|
test "estimate_tokens rounds chars/4 up" {
  inspect(estimate_tokens(""), content="0")
  inspect(estimate_tokens("a"), content="1")
  inspect(estimate_tokens("abcd"), content="1")
  inspect(estimate_tokens("abcde"), content="2")
  inspect(estimate_tokens("abcdefgh"), content="2")
  inspect(estimate_tokens("abcdefghi"), content="3")
}
