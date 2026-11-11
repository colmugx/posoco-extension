///|
test "fold_case folds non-ASCII, not just ASCII" {
  assert_eq(fold_case("ÜBER"), "über")
  assert_eq(fold_case("Échec"), "échec")
  assert_eq(fold_case("流水线 CJK"), "流水线 cjk")
  // Length-preserving: the full mapping would turn ß into two scalars and shift
  // every offset a line matcher reports.
  assert_eq(fold_case("Straße"), "straße")
  assert_eq(fold_case("plain ascii"), "plain ascii")
  assert_eq(fold_case(""), "")
}

///|
test "is_ascii separates the allocation-free lane from the folding lane" {
  assert_true(is_ascii("moonbit-orientation"))
  assert_true(is_ascii(""))
  assert_false(is_ascii("über"))
  assert_false(is_ascii("a🙂"))
}
