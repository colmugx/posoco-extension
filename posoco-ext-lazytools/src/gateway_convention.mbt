///|
/// The gateway call convention, as a public pair of helpers.
///
/// A deferred invocation travels as an `execute` call whose `tool` argument
/// names the real tool and whose `arguments` object carries the tool's own
/// arguments. Kernel-level hooks (permission gating, rtk shell rewriting)
/// need the inner identity to classify and the outer shape to return, so
/// both directions live here — one convention, one implementation.

///|
/// Resolve the tool identity a gateway call will actually execute. Returns
/// the inner name and an inner call with the nested arguments unwrapped
/// (same call id). Non-gateway calls and malformed gateway calls come back
/// unchanged with their outer name, so consumers classify and route by the
/// returned name alone.
pub fn LazyTools::unwrap_call(
  call : @posoco.ToolCall,
) -> (String, @posoco.ToolCall) {
  let name = call.name.to_string()
  if name != "tool_execute" {
    return (name, call)
  }
  match call.arguments {
    Json::Object(obj) =>
      match obj.get("tool") {
        Some(Json::String(inner)) if inner != "" => {
          let arguments : Json = match obj.get("arguments") {
            Some(Json::Object(args)) => Json::object(args)
            _ => Json::object(Map::from_array([]))
          }
          (
            inner,
            {
              call_id: call.call_id,
              name: @posoco.ToolName::unchecked(inner),
              arguments,
            },
          )
        }
        _ => (name, call)
      }
    _ => (name, call)
  }
}

///|
/// Is `name` one of the gateway's meta tools (`tool_list`/`tool_execute`)?
/// Gates use this to exempt the discovery surface: neither meta tool has
/// side effects of its own — `tool_list` only reads the folded index, and
/// a well-formed `tool_execute` reaches gates under its inner tool's name
/// (see `unwrap_call`), the literal name surviving only for malformed
/// calls that execute nothing.
pub fn LazyTools::is_meta_tool(name : String) -> Bool {
  name == "tool_list" || name == "tool_execute"
}

///|
/// Rebuild a gateway call around a rewritten inner call: outer name, call
/// id, and unrelated outer argument keys are preserved; the inner call's
/// name and arguments replace the `tool` / `arguments` entries. Inverse of
/// `unwrap_call` — hooks that rewrite deferred calls (permission consents,
/// rtk command rewrites) hand the kernel back this outer shape, which the
/// gateway routes exactly like the original call.
pub fn LazyTools::rewrap_call(
  original : @posoco.ToolCall,
  inner : @posoco.ToolCall,
) -> @posoco.ToolCall {
  let outer : Map[String, Json] = match original.arguments {
    Json::Object(obj) => {
      let m : Map[String, Json] = Map::from_array([])
      for key in obj.keys() {
        m[key] = obj[key]
      }
      m
    }
    _ => Map::from_array([])
  }
  outer["tool"] = Json::string(inner.name.to_string())
  outer["arguments"] = match inner.arguments {
    Json::Object(args) => Json::object(args)
    other => other
  }
  {
    call_id: original.call_id,
    name: original.name,
    arguments: Json::object(outer),
  }
}
