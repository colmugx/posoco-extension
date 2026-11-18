///|
/// The gateway's public naming convention.
///
/// A deferred invocation travels as a `tool_execute` call whose `tool`
/// argument names the real tool and whose `arguments` object carries that
/// tool's own arguments. Nothing else needs to know the shape: the child call
/// is admitted by the kernel and reaches every hook under its own name, so
/// gates classify the real tool without unwrapping or rewrapping the envelope.

///|
/// Is `name` one of the gateway's meta tools (`tool_list`/`tool_execute`)?
/// Gates use this to exempt the discovery surface: neither meta tool has side
/// effects of its own, and the real tool reaches every gate as its own child
/// call.
pub fn LazyTools::is_meta_tool(name : String) -> Bool {
  name == "tool_list" || name == "tool_execute"
}
