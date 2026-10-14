///|
/// A caller-selected, known-stable boundary. The kit intentionally does NOT
/// guess that a changing system block is stable. Mark the last tool definition
/// or last system text block, so the provider caches precisely the stable
/// tools -> system prefix rather than a per-turn volatile tail.
pub(all) enum MessagesStablePrefix {
  StableTools
  StableSystem
} derive(Eq, Debug)

///|
pub extend MessagesStablePrefix with Eq::{equal, not_equal}

///|
pub extend MessagesStablePrefix with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Copy-on-write: preserve the caller's original JSON when adding a cache
/// checkpoint. Validate existing TTL on that block rather than overwriting.
pub fn mark_messages_stable_prefix(
  body : Json,
  prefix : MessagesStablePrefix,
  ttl~ : String = "5m",
) -> Json raise @posoco.ModelError {
  let cc : CacheControl = { ttl: Some(ttl), }
  let marker = cc.to_wire()
  guard body is Json::Object(fields) else {
    raise @posoco.ModelError::RequestBuild(
      "messages stable prefix requires an object (stage=cache, category=body)",
    )
  }
  let location = match prefix {
    StableTools => "tools"
    StableSystem => "system"
  }
  let values = match fields.get(location) {
    Some(Json::Array(values)) if !values.is_empty() => values
    _ =>
      raise @posoco.ModelError::RequestBuild(
        "messages stable-prefix target is absent (stage=cache, category=stable_prefix)",
      )
  }
  let last = values.length() - 1
  guard values[last] is Json::Object(block) else {
    raise @posoco.ModelError::RequestBuild(
      "messages stable-prefix block must be an object (stage=cache, category=stable_prefix)",
    )
  }
  if location == "system" && block.get("type") != Some(Json::string("text")) {
    raise @posoco.ModelError::RequestBuild(
      "messages stable system prefix must end in a text block (stage=cache, category=stable_prefix)",
    )
  }
  match block.get("cache_control") {
    Some(old_mark) =>
      if old_mark != marker {
        raise @posoco.ModelError::RequestBuild(
          "messages stable-prefix mark has conflicting TTL (stage=cache, category=ttl_conflict)",
        )
      }
    None => ()
  }
  let new_items = values.copy()
  new_items[last] = attach_cache_control(values[last], cache_control=cc)
  let new_fields : Map[String, Json] = Map::from_array([])
  for entry in fields {
    let (name, value) = entry
    new_fields[name] = value
  }
  new_fields[location] = Json::array(new_items)
  let updated = Json::object(new_fields)
  // Validate complete prefix order, count and TTL constraints.
  apply_messages_cache_policy(updated, CacheExplicit)
}
