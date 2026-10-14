///|
/// Native Messages cache policy. This deliberately does NOT emulate OpenAI
/// prompt_cache_key; Messages caches the exact tools -> system -> messages
/// prefix and places an ephemeral breakpoint on a content block or request.
///
/// Automatic modes use the protocol's top-level cache_control. Explicit mode
/// validates caller-inserted block marks but does not move them.
/// Never silently downgrade a requested TTL or caching capability.
pub(all) enum MessagesCacheMode {
  CacheUnchanged
  CacheAutomatic5m
  CacheAutomatic1h
  CacheExplicit
} derive(Eq, Debug)

///|
pub extend MessagesCacheMode with Eq::{equal, not_equal}

///|
pub extend MessagesCacheMode with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Capability declaration of the actual endpoint. The kit does not infer it
/// from model spelling. A gateway that cannot preserve native Messages cache
/// semantics must declare automatic=false / one_hour=false explicitly.
pub(all) struct MessagesCacheCapabilities {
  automatic : Bool
  one_hour : Bool
} derive(Eq, Debug)

///|
pub extend MessagesCacheCapabilities with Eq::{equal, not_equal}

///|
pub extend MessagesCacheCapabilities with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn MessagesCacheCapabilities::native() -> MessagesCacheCapabilities {
  { automatic: true, one_hour: true }
}

///|
priv struct CacheMarkScan {
  mut explicit_count : Int
  mut seen_five_minute : Bool
  mut last_cacheable_ttl : String?
  mut last_cacheable_kind : String
  mut content_blocks : Int
  mut latest_explicit_block : Int
  mut has_one_hour : Bool
  mut previous_position_kind : String
}

///|
fn CacheMarkScan::new() -> CacheMarkScan {
  {
    explicit_count: 0,
    seen_five_minute: false,
    last_cacheable_ttl: None,
    last_cacheable_kind: "",
    content_blocks: 0,
    latest_explicit_block: 0,
    has_one_hour: false,
    previous_position_kind: "",
  }
}

///|
fn cache_mark_ttl(mark : Json) -> String raise @posoco.ModelError {
  guard mark is Json::Object(fields) else {
    raise @posoco.ModelError::RequestBuild(
      "messages cache_control must be an object (stage=cache, category=shape)",
    )
  }
  if fields.get("type") != Some(Json::string("ephemeral")) {
    raise @posoco.ModelError::RequestBuild(
      "messages cache_control requires type ephemeral (stage=cache, category=type)",
    )
  }
  match fields.get("ttl") {
    None | Some(Json::Null) | Some(Json::String("5m")) => "5m"
    Some(Json::String("1h")) => "1h"
    _ =>
      raise @posoco.ModelError::RequestBuild(
        "messages cache_control ttl must be 5m or 1h (stage=cache, category=ttl)",
      )
  }
}

///|
fn inspect_cache_block(
  scan : CacheMarkScan,
  block : Json,
  kind : String,
  cacheable : Bool,
) -> Unit raise @posoco.ModelError {
  // Native lookback counts a consecutive batch of tool_use or
  // tool_result blocks in one message as ONE position.
  if !((kind == "tool_use" || kind == "tool_result") &&
    scan.previous_position_kind == kind) {
    scan.content_blocks += 1
  }
  scan.previous_position_kind = kind
  if cacheable {
    scan.last_cacheable_kind = kind
    scan.last_cacheable_ttl = None
  }
  match block {
    Json::Object(fields) =>
      match fields.get("cache_control") {
        Some(value) => {
          if !cacheable {
            raise @posoco.ModelError::RequestBuild(
              "messages cache_control is not supported on this content block (stage=cache, category=placement)",
            )
          }
          let ttl = cache_mark_ttl(value)
          if ttl == "1h" {
            if scan.seen_five_minute {
              raise @posoco.ModelError::RequestBuild(
                "messages 1h cache breakpoints must precede 5m breakpoints (stage=cache, category=ttl_order)",
              )
            }
            scan.has_one_hour = true
          } else {
            scan.seen_five_minute = true
          }
          scan.explicit_count += 1
          scan.latest_explicit_block = scan.content_blocks
          scan.last_cacheable_ttl = Some(ttl)
        }
        None => ()
      }
    _ => ()
  }
}

///|
fn inspect_messages_cache(body : Json) -> CacheMarkScan raise @posoco.ModelError {
  guard body is Json::Object(root) else {
    raise @posoco.ModelError::RequestBuild(
      "messages cache request must be an object (stage=cache, category=body)",
    )
  }
  let scan = CacheMarkScan::new()
  match root.get("tools") {
    Some(Json::Array(tools)) =>
      for tool in tools {
        inspect_cache_block(scan, tool, "tool", true)
      }
    Some(_) =>
      raise @posoco.ModelError::RequestBuild(
        "messages tools must be an array (stage=cache, category=tools)",
      )
    None => ()
  }
  match root.get("system") {
    Some(Json::Array(blocks)) =>
      for block in blocks {
        let cacheable = match block {
          Json::Object(fields) => fields.get("type") == Some(Json::string("text"))
          _ => false
        }
        inspect_cache_block(scan, block, "system", cacheable)
      }
    Some(Json::String(_)) => scan.content_blocks += 1
    Some(_) =>
      raise @posoco.ModelError::RequestBuild(
        "messages system must be text or content blocks (stage=cache, category=system)",
      )
    None => ()
  }
  match root.get("messages") {
    Some(Json::Array(messages)) =>
      for message in messages {
        scan.previous_position_kind = ""
        guard message is Json::Object(msg) else {
          raise @posoco.ModelError::RequestBuild(
            "messages message must be an object (stage=cache, category=message)",
          )
        }
        match msg.get("content") {
          Some(Json::Array(blocks)) =>
            for block in blocks {
              let (kind, cacheable) = match block {
                Json::Object(fields) =>
                  match fields.get("type") {
                    Some(Json::String("text")) =>
                      ("text", match fields.get("text") {
                        Some(Json::String(text)) => text != ""
                        _ => false
                      })
                    Some(Json::String("image")) => ("image", true)
                    Some(Json::String("tool_result")) => ("tool_result", true)
                    Some(Json::String("tool_use")) => ("tool_use", true)
                    _ => ("unknown", false)
                  }
                _ => ("unknown", false)
              }
              inspect_cache_block(scan, block, kind, cacheable)
            }
          Some(Json::String(_)) => scan.content_blocks += 1
          _ =>
            raise @posoco.ModelError::RequestBuild(
              "messages message content must be text or blocks (stage=cache, category=content)",
            )
        }
      }
    _ =>
      raise @posoco.ModelError::RequestBuild(
        "messages request needs a message array (stage=cache, category=messages)",
      )
  }
  scan
}

///|
/// Validate the complete prefix in protocol order: tools -> system ->
/// messages. Automatic mode consumes one of four available breakpoint slots;
/// a same-TTL explicit mark on the final eligible block makes it a no-op.
/// Different TTLs on the same automatic target are an API 400, not a hint
/// to silently change the TTL. Return a fresh request JSON on modification.
pub fn apply_messages_cache_policy(
  body : Json,
  mode : MessagesCacheMode,
  capabilities~ : MessagesCacheCapabilities = MessagesCacheCapabilities::native(),
) -> Json raise @posoco.ModelError {
  let scan = inspect_messages_cache(body)
  if scan.explicit_count > 4 {
    raise @posoco.ModelError::RequestBuild(
      "messages accepts at most four explicit breakpoints (stage=cache, category=breakpoints)",
    )
  }
  if scan.has_one_hour && !capabilities.one_hour {
    raise @posoco.ModelError::RequestBuild(
      "messages endpoint does not support 1h caching (stage=cache, category=capability)",
    )
  }
  let ttl = match mode {
    CacheAutomatic5m => Some("5m")
    CacheAutomatic1h => Some("1h")
    CacheUnchanged | CacheExplicit => None
  }
  match ttl {
    None => body
    Some(requested_ttl) => {
      if !capabilities.automatic || (requested_ttl == "1h" && !capabilities.one_hour) {
        raise @posoco.ModelError::RequestBuild(
          "messages endpoint cannot preserve automatic cache policy (stage=cache, category=capability)",
        )
      }
      if scan.explicit_count >= 4 {
        raise @posoco.ModelError::RequestBuild(
          "messages automatic caching needs a free breakpoint slot (stage=cache, category=breakpoints)",
        )
      }
      if requested_ttl == "1h" && scan.seen_five_minute {
        raise @posoco.ModelError::RequestBuild(
          "messages automatic 1h cache cannot follow 5m marks (stage=cache, category=ttl_order)",
        )
      }
      // The Messages API itself walks backwards to the final eligible block.
      // When that block has an explicit mark, differing TTLs are a 400.
      match scan.last_cacheable_ttl {
        Some(existing) if existing != requested_ttl =>
          raise @posoco.ModelError::RequestBuild(
            "messages automatic cache conflicts with final explicit TTL (stage=cache, category=ttl_conflict)",
          )
        _ => ()
      }
      guard body is Json::Object(root) else {
        raise @posoco.ModelError::RequestBuild(
          "messages cache request must be an object (stage=cache, category=body)",
        )
      }
      let copied : Map[String, Json] = Map::from_array([])
      for entry in root {
        let (key, value) = entry
        copied[key] = value
      }
      copied["cache_control"] = if requested_ttl == "1h" {
        Json::object({
          "type": Json::string("ephemeral"),
          "ttl": Json::string("1h"),
        })
      } else {
        Json::object({ "type": Json::string("ephemeral") })
      }
      Json::object(copied)
    }
  }
}

///|
/// Cache lookback is limited to 20 blocks. This is a *risk diagnostic*, not
/// a cache-hit prediction: cache entries and upstream account affinity are
/// outside the kit's view. Use a stable explicit checkpoint when a caller
/// KNOWS that more than 20 cacheable blocks will arrive between reuse points.
pub(all) struct MessagesCacheLayout {
  explicit_breakpoints : Int
  scanned_blocks : Int
  blocks_since_last_explicit : Int
  lookback_risk : Bool
} derive(Eq, Debug)

///|
pub extend MessagesCacheLayout with Eq::{equal, not_equal}

///|
pub extend MessagesCacheLayout with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn inspect_messages_cache_layout(body : Json) -> MessagesCacheLayout raise @posoco.ModelError {
  let scan = inspect_messages_cache(body)
  let distance = scan.content_blocks - scan.latest_explicit_block
  {
    explicit_breakpoints: scan.explicit_count,
    scanned_blocks: scan.content_blocks,
    blocks_since_last_explicit: distance,
    lookback_risk: distance >= 20,
  }
}

///|
/// Compare two already-encoded requests. No fuzzy hashing or guessed hits:
/// all earlier messages must be structurally identical, with the same model,
/// tool definitions, system prompt and cache-relevant generation settings.
/// The diagnostic only establishes *prefix stability*, not cache existence.
pub(all) struct MessagesCachePrefixComparison {
  model_stable : Bool
  tools_stable : Bool
  system_stable : Bool
  history_is_prefix : Bool
  request_settings_stable : Bool
  prefix_reusable : Bool
  suffix_message_count : Int
} derive(Eq, Debug)

///|
pub extend MessagesCachePrefixComparison with Eq::{equal, not_equal}

///|
pub extend MessagesCachePrefixComparison with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn compare_messages_cache_prefix(
  previous : Json,
  current : Json,
) -> MessagesCachePrefixComparison raise @posoco.ModelError {
  guard previous is Json::Object(a) && current is Json::Object(b) else {
    raise @posoco.ModelError::RequestBuild(
      "messages cache prefix comparison needs objects (stage=cache, category=body)",
    )
  }
  let pa = match a.get("messages") {
    Some(Json::Array(arr)) => arr
    _ => []
  }
  let pb = match b.get("messages") {
    Some(Json::Array(arr)) => arr
    _ => []
  }
  let mut is_prefix = pa.length() <= pb.length()
  if is_prefix {
    for i in 0..<pa.length() {
      if pa[i] != pb[i] {
        is_prefix = false
      }
    }
  }
  let model_stable = a.get("model") == b.get("model")
  let tools_stable = a.get("tools") == b.get("tools")
  let system_stable = a.get("system") == b.get("system")
  let mut settings_stable = true
  // These request-level settings may affect provider cache matching.
  // Never label a prefix reusable after a known cache-relevant change.
  for key in ["thinking", "output_config", "tool_choice", "temperature", "top_p", "top_k", "stop_sequences"] {
    if a.get(key) != b.get(key) {
      settings_stable = false
    }
  }
  {
    model_stable,
    tools_stable,
    system_stable,
    history_is_prefix: is_prefix,
    request_settings_stable: settings_stable,
    prefix_reusable: model_stable && tools_stable && system_stable && is_prefix && settings_stable,
    suffix_message_count: if is_prefix { pb.length() - pa.length() } else { 0 },
  }
}
