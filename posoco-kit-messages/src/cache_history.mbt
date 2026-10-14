///|
/// Explicit cache checkpoints inside a caller-asserted *stable* conversation
/// prefix. This helper is opt-in: it must never guess which recent turn,
/// retrieved context, or tool response will change on the next request.
///
/// The native Messages 20-position lookback counts consecutive tool_use or
/// tool_result blocks in a turn as one position. For safety, markers are
/// placed only on eligible USER text/image/tool_result blocks: a signed
/// assistant replay envelope must remain bit-for-bit untouched.
///
/// The algorithm aims for <=18 positions between checkpoints and refuses a
/// plan that cannot be expressed with the 4-breakpoint budget. It cannot
/// guarantee a cache hit (minimum prefix size, TTL and upstream affinity
/// belong to the provider).
pub fn mark_messages_stable_history_checkpoints(
  body : Json,
  stable_messages~ : Int,
  ttl~ : String = "5m",
  reserve_automatic_slot~ : Bool = true,
) -> Json raise @posoco.ModelError {
  let cc : CacheControl = { ttl: Some(ttl) }
  ignore(cc.to_wire())
  guard body is Json::Object(root) else {
    raise @posoco.ModelError::RequestBuild(
      "messages history checkpoint request must be object (stage=cache, category=body)",
    )
  }
  let messages = match root.get("messages") {
    Some(Json::Array(items)) => items
    _ =>
      raise @posoco.ModelError::RequestBuild(
        "messages history checkpoint requires message array (stage=cache, category=messages)",
      )
  }
  if stable_messages < 0 || stable_messages > messages.length() {
    raise @posoco.ModelError::RequestBuild(
      "messages history checkpoint count exceeds transcript (stage=cache, category=stable_history)",
    )
  }
  if stable_messages == 0 {
    return body
  }
  // (message index, block index, native position) for eligible USER blocks.
  let choices : Array[(Int, Int, Int)] = []
  let mut position = 0
  let mut last_mark_position = 0
  let mut last_candidate : (Int, Int, Int)? = None
  for message_idx in 0..<stable_messages {
    guard messages[message_idx] is Json::Object(message) else {
      raise @posoco.ModelError::RequestBuild(
        "messages history checkpoint requires object message (stage=cache, category=message)",
      )
    }
    let user = message.get("role") == Some(Json::string("user"))
    let mut prior_kind = ""
    match message.get("content") {
      Some(Json::Array(blocks)) =>
        for block_idx, block in blocks {
          let kind = match block {
            Json::Object(fields) =>
              match fields.get("type") {
                Some(Json::String(name)) => name
                _ => ""
              }
            _ => ""
          }
          if !((kind == "tool_use" || kind == "tool_result") && kind == prior_kind) {
            position += 1
          }
          prior_kind = kind
          if user {
            let eligible = match block {
              Json::Object(fields) =>
                match kind {
                  "text" =>
                    match fields.get("text") {
                      Some(Json::String(text)) => text != ""
                      _ => false
                    }
                  "image" | "tool_result" => true
                  _ => false
                }
              _ => false
            }
            if eligible {
              last_candidate = Some((message_idx, block_idx, position))
            }
          }
          if position - last_mark_position >= 18 {
            match last_candidate {
              Some((mi, bi, spot)) if spot > last_mark_position &&
                position - spot < 20 => {
                choices.push((mi, bi, spot))
                last_mark_position = spot
              }
              _ =>
                raise @posoco.ModelError::RequestBuild(
                  "messages stable history lacks a safe cache checkpoint inside lookback window (stage=cache, category=lookback)",
                )
            }
          }
        }
      Some(Json::String(_)) => position += 1
      _ =>
        raise @posoco.ModelError::RequestBuild(
          "messages stable history content must be text or blocks (stage=cache, category=content)",
        )
    }
  }
  match last_candidate {
    Some((mi, bi, spot)) if spot > last_mark_position =>
      choices.push((mi, bi, spot))
    _ => ()
  }
  if choices.is_empty() {
    return body
  }
  let rewritten = messages.copy()
  for (mi, bi, _) in choices {
    guard rewritten[mi] is Json::Object(msg) else {
      raise @posoco.ModelError::RequestBuild(
        "messages history checkpoint message is invalid (stage=cache, category=message)",
      )
    }
    guard msg.get("content") is Some(Json::Array(parts)) else {
      raise @posoco.ModelError::RequestBuild(
        "messages history checkpoint content is invalid (stage=cache, category=content)",
      )
    }
    guard parts[bi] is Json::Object(block) else {
      raise @posoco.ModelError::RequestBuild(
        "messages history checkpoint block is invalid (stage=cache, category=block)",
      )
    }
    match block.get("cache_control") {
      Some(old) =>
        if old != cc.to_wire() {
          raise @posoco.ModelError::RequestBuild(
            "messages history checkpoint conflicts with existing TTL (stage=cache, category=ttl_conflict)",
          )
        }
      None => ()
    }
    let copied_parts = parts.copy()
    copied_parts[bi] = attach_cache_control(parts[bi], cache_control=cc)
    let copied_message : Map[String, Json] = Map::from_array([])
    for pair in msg {
      let (key, value) = pair
      copied_message[key] = value
    }
    copied_message["content"] = Json::array(copied_parts)
    rewritten[mi] = Json::object(copied_message)
  }
  let copied_root : Map[String, Json] = Map::from_array([])
  for pair in root {
    let (key, value) = pair
    copied_root[key] = value
  }
  copied_root["messages"] = Json::array(rewritten)
  let result = Json::object(copied_root)
  let layout = inspect_messages_cache_layout(result)
  let limit = if reserve_automatic_slot { 3 } else { 4 }
  if layout.explicit_breakpoints > limit {
    raise @posoco.ModelError::RequestBuild(
      "messages stable history requires too many cache breakpoints (stage=cache, category=breakpoints)",
    )
  }
  apply_messages_cache_policy(result, CacheExplicit)
}
