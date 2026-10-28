///|
/// One shaped child story: the concrete create request of a split or of the
/// shaper itself. Everything is already trimmed and validated by the parsers
/// below, so the Board create command never sees a blank required field.
pub(all) struct ShapeChild {
  title : String
  user_story : String
  description : String
  implementation_suggestions : String
  definition_of_done : Array[String]
  priority : String
} derive(Eq, Debug)

///|
pub extend ShapeChild with Eq::{equal, not_equal}

///|
pub extend ShapeChild with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Pull the first balanced JSON object out of a model answer. Shaping models
/// wrap the requested object in prose or fences; a strict parse of the whole
/// text would reject an otherwise correct story.
pub fn extract_json_object(text : String) -> Json? {
  let trimmed = text.trim()
  let mut start = -1
  let mut end = -1
  for index in 0..<trimmed.length() {
    if trimmed[index] == '{' && start < 0 {
      start = index
    }
    if trimmed[index] == '}' {
      end = index
    }
  }
  if start < 0 || end <= start {
    return None
  }
  let parsed = @json.parse(trimmed[start:end + 1]) catch { _ => return None }
  Some(parsed)
}

///|
pub fn shape_priority(value : String) -> String? {
  match value.trim().to_owned() {
    "p0" | "critical" => Some("critical")
    "p1" | "high" => Some("high")
    "p2" | "normal" => Some("normal")
    "p3" | "low" => Some("low")
    _ => None
  }
}

///|
fn shape_text(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(String(value)) => value.trim().to_owned()
    _ => ""
  }
}

///|
/// Parse one shaped story. `title_fallback` lets a split reuse the source
/// ticket's title when the model omits it; every other blank field is a
/// rejection, because the Board create command requires them all.
pub fn parse_shape_story(
  fields : Map[String, Json],
  fallback_priority : String,
  title_fallback? : String,
) -> Result[ShapeChild, String] {
  let title = match shape_text(fields, "title") {
    "" =>
      match title_fallback {
        Some(value) => value.trim().to_owned()
        None => ""
      }
    title => title
  }
  if title == "" {
    return Err("every shaped story needs a title")
  }
  let user_story = shape_text(fields, "user_story")
  if user_story == "" {
    return Err("every shaped story needs a user_story")
  }
  let description = shape_text(fields, "description")
  if description == "" {
    return Err("every shaped story needs a description")
  }
  let implementation_suggestions = shape_text(
    fields,
    "implementation_suggestions",
  )
  if implementation_suggestions == "" {
    return Err("every shaped story needs implementation_suggestions")
  }
  let definition_of_done = match fields.get("definition_of_done") {
    Some(Array(values)) =>
      values.filter_map(value => {
        match value {
          String(text) =>
            if text.trim() == "" {
              None
            } else {
              Some(text.trim().to_owned())
            }
          _ => None
        }
      })
    _ => []
  }
  if definition_of_done.is_empty() {
    return Err("every shaped story needs at least one definition_of_done item")
  }
  let priority = match fields.get("priority") {
    Some(String(value)) =>
      match shape_priority(value) {
        Some(priority) => priority
        None => return Err("priority must be p0, p1, p2, or p3")
      }
    None => fallback_priority
    _ => return Err("priority must be a string")
  }
  Ok({
    title,
    user_story,
    description,
    implementation_suggestions,
    definition_of_done,
    priority,
  })
}

///|
/// Parse a shaping split: between two and eight independent tickets, each a
/// valid story. Fewer than two is not a split; more than eight is a plan the
/// host will not orchestrate in one step.
pub fn parse_shape_children(
  value : Json?,
  fallback_priority : String,
) -> Result[Array[ShapeChild], String] {
  let items = match value {
    Some(Array(items)) => items
    _ => return Err("shaping split has no tasks array")
  }
  if items.length() < 2 {
    return Err("a split needs at least two independent tickets")
  }
  if items.length() > 8 {
    return Err("a split is limited to eight independent tickets")
  }
  let children : Array[ShapeChild] = []
  for item in items {
    let fields = match item {
      Object(fields) => fields
      _ => return Err("every split ticket must be an object")
    }
    let child = match parse_shape_story(fields, fallback_priority) {
      Ok(child) => child
      Err(reason) => return Err("split story: " + reason)
    }
    children.push(child)
  }
  Ok(children)
}
