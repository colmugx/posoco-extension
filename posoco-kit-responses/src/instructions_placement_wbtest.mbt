///|
test "reusable instructions take the leading developer message" {
  let (items, field) = place_reusable_instructions(
    [@json.parse("{\"role\":\"user\",\"content\":\"hi\"}")],
    "be terse",
  )
  assert_eq(field, "")
  assert_eq(items.length(), 2)
  assert_eq(
    items[0],
    @json.parse(
      "{\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"be terse\"}]}",
    ),
  )
}

///|
test "empty instructions and ineligible backends pass through" {
  let input : Array[Json] = [@json.parse("{\"role\":\"user\"}")]
  let (items, field) = place_reusable_instructions(input, "")
  assert_eq(field, "")
  assert_eq(items.length(), 1)
  let (kept, field2) = place_reusable_instructions(
    input,
    "be terse",
    eligible=false,
  )
  assert_eq(field2, "be terse")
  assert_eq(kept.length(), 1)
}

///|
test "developer instructions message carries the text as input content" {
  let item = developer_instructions_message("be terse")
  guard item is Json::Object(fields) else { fail("item") }
  assert_eq(fields.get("role"), Some(Json::string("developer")))
  assert_eq(
    fields.get("content"),
    Some(@json.parse("[{\"type\":\"input_text\",\"text\":\"be terse\"}]")),
  )
}
