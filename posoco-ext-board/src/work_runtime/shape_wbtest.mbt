///|
test "extract_json_object reads the first balanced object out of prose" {
  match extract_json_object("Sure:\n```json\n{\"title\": \"x\"}\n```") {
    Some(Object(fields)) => assert_true(fields.get("title") is Some(_))
    _ => fail("the fenced object must be extracted")
  }
  assert_true(extract_json_object("no object here") is None)
  assert_true(extract_json_object("{ not json") is None)
}

///|
test "shape priority accepts the bounded aliases" {
  assert_eq(shape_priority("p0"), Some("critical"))
  assert_eq(shape_priority(" critical "), Some("critical"))
  assert_true(shape_priority("CRITICAL") is None)
  assert_eq(shape_priority("p1"), Some("high"))
  assert_eq(shape_priority("p2"), Some("normal"))
  assert_eq(shape_priority("p3"), Some("low"))
  assert_eq(shape_priority("urgent"), None)
}

///|
fn shape_story_fields(title~ : String = "A story") -> Map[String, Json] {
  Map::from_array([
    ("title", Json::string(title)),
    ("user_story", Json::string("As a user, I want x, so that y.")),
    ("description", Json::string("Do the thing.")),
    ("implementation_suggestions", Json::string("Start small.")),
    (
      "definition_of_done",
      Json::array([Json::string("evidence"), Json::string("  ")]),
    ),
  ])
}

///|
test "shaped story requires every create field" {
  let story = match parse_shape_story(shape_story_fields(), "normal") {
    Ok(story) => story
    Err(reason) => fail("a complete story must parse: " + reason)
  }
  assert_eq(story.title, "A story")
  assert_eq(story.priority, "normal")
  assert_eq(story.definition_of_done, ["evidence"])
  assert_true(parse_shape_story(Map([]), "normal") is Err(_))
  let no_story = shape_story_fields()
  no_story.remove("user_story")
  assert_true(parse_shape_story(no_story, "normal") is Err(_))
  let no_description = shape_story_fields()
  no_description["description"] = Json::string("  ")
  assert_true(parse_shape_story(no_description, "normal") is Err(_))
  let no_suggestions = shape_story_fields()
  no_suggestions.remove("implementation_suggestions")
  assert_true(parse_shape_story(no_suggestions, "normal") is Err(_))
  let no_done = shape_story_fields()
  no_done["definition_of_done"] = Json::array([])
  assert_true(parse_shape_story(no_done, "normal") is Err(_))
  let bad_priority = shape_story_fields()
  bad_priority["priority"] = Json::string("urgent")
  assert_true(parse_shape_story(bad_priority, "normal") is Err(_))
}

///|
test "shaped story falls back to the given title and priority" {
  let fields = shape_story_fields()
  fields.remove("title")
  fields["priority"] = Json::string("p1")
  let story = match
    parse_shape_story(fields, "normal", title_fallback="Source ticket") {
    Ok(story) => story
    Err(reason) => fail("the fallback story must parse: " + reason)
  }
  assert_eq(story.title, "Source ticket")
  assert_eq(story.priority, "high")
  let blank_title = shape_story_fields()
  blank_title["title"] = Json::string("  ")
  assert_true(parse_shape_story(blank_title, "normal") is Err(_))
}

///|
test "a split needs two to eight independent tickets" {
  let one = Json::array([Json::object(shape_story_fields())])
  assert_eq(
    parse_shape_children(Some(one), "normal"),
    Err("a split needs at least two independent tickets"),
  )
  let nine : Array[Json] = []
  for _ in 0..<9 {
    nine.push(Json::object(shape_story_fields()))
  }
  assert_eq(
    parse_shape_children(Some(Json::array(nine)), "normal"),
    Err("a split is limited to eight independent tickets"),
  )
  assert_eq(
    parse_shape_children(None, "normal"),
    Err("shaping split has no tasks array"),
  )
  let stray = Json::array([
    Json::string("nope"),
    Json::object(shape_story_fields()),
  ])
  assert_eq(
    parse_shape_children(Some(stray), "normal"),
    Err("every split ticket must be an object"),
  )
  let broken = Json::array([
    Json::object(shape_story_fields()),
    Json::object(Map::from_array([("title", Json::string("x"))])),
  ])
  assert_eq(
    parse_shape_children(Some(broken), "normal"),
    Err("split story: every shaped story needs a user_story"),
  )
}

///|
test "a valid split parses every child" {
  let pair = Json::array([
    Json::object(shape_story_fields(title="One")),
    Json::object(shape_story_fields(title="Two")),
  ])
  let children = match parse_shape_children(Some(pair), "normal") {
    Ok(children) => children
    Err(reason) => fail("a valid split must parse: " + reason)
  }
  assert_eq(children.length(), 2)
  assert_eq(children[0].title, "One")
  assert_eq(children[1].title, "Two")
}
