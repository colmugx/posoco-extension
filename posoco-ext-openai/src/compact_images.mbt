///|
/// context_manager/history.rs image reference estimate. Normal images use
/// 7373 bytes; original-detail file references use the 10,000-patch bound.
/// This adapter has no image decoder; inline original-detail references use
/// the same upstream unavailable/decode-failed fallback, not payload length.
fn compact_content_tokens(part : Json) -> Int {
  match compact_part_text(part) {
    Some(text) => compact_approx_tokens(text)
    None =>
      match part {
        Json::Object(fields) if fields.get("type") ==
          Some(Json::string("input_image")) =>
          if fields.get("detail") == Some(Json::string("original")) &&
            fields.contains("file_id") {
            10_000
          } else {
            (7373 + 3) / 4
          }
        _ => 0
      }
  }
}

///|
fn compact_message_content_tokens(item : Json) -> Int {
  let mut tokens = 0
  for part in compact_message_parts(item) {
    tokens += compact_content_tokens(part)
  }
  tokens
}

///|
fn compact_has_image(item : Json) -> Bool {
  compact_message_parts(item).any(fn(part) {
    match part {
      Json::Object(fields) =>
        fields.get("type") == Some(Json::string("input_image"))
      _ => false
    }
  })
}

///|
fn compact_image_open(text : String) -> Bool {
  text == "<image>" || (text.has_prefix("<image name=") && text.has_suffix(">"))
}

///|
/// compact_remote_v2_images.rs: later parts of a boundary message first;
/// images and immediately adjacent harness labels are indivisible.
fn compact_truncate_image_message(item : Json, budget : Int) -> Json? {
  guard json_deep_copy(item) is Json::Object(fields) else { return None }
  let content = compact_message_parts(Json::object(fields))
  let reversed : Array[Json] = []
  let mut remaining = budget
  let mut end = content.length()
  while end > 0 {
    let last = end - 1
    let image = match content[last] {
      Json::Object(part) if part.get("type") ==
        Some(Json::string("input_image")) => Some(last)
      _ =>
        if compact_part_text(content[last]) == Some("</image>") && last > 0 {
          match content[last - 1] {
            Json::Object(part) if part.get("type") ==
              Some(Json::string("input_image")) => Some(last - 1)
            _ => None
          }
        } else {
          None
        }
    }
    match image {
      Some(index) => {
        let has_open = index > 0 &&
          (match compact_part_text(content[index - 1]) {
            Some(text) => compact_image_open(text)
            None => false
          })
        let start = index - (if has_open { 1 } else { 0 })
        let mut tokens = 0
        for i in start..<end {
          tokens += compact_content_tokens(content[i])
        }
        let fits = tokens <= remaining
        remaining = if fits { remaining - tokens } else { 0 }
        if fits {
          for i = end - 1; i >= start; i = i - 1 {
            reversed.push(content[i])
          }
        }
        end = start
      }
      None => {
        end -= 1
        match compact_part_text(content[last]) {
          Some(text) => {
            if remaining == 0 {
              continue
            }
            let tokens = compact_approx_tokens(text)
            let text = if tokens <= remaining {
              remaining -= tokens
              text
            } else {
              let truncated = compact_truncate_text(text, remaining)
              remaining = 0
              truncated
            }
            if !text.is_empty() {
              guard content[last] is Json::Object(part) else {
                abort("text part")
              }
              part["text"] = Json::string(text)
              reversed.push(Json::object(part))
            }
          }
          None => reversed.push(content[last])
        }
      }
    }
  }
  if reversed.is_empty() {
    return None
  }
  fields["content"] = Json::array(
    [
      for i = reversed.length() - 1; i >= 0; i = i - 1 => reversed[i]
    ],
  )
  Some(Json::object(fields))
}
