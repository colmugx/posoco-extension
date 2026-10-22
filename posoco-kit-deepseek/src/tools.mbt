///|
/// Canonical tool declaration order.
///
/// DeepSeek renders the tool schema into the stable part of the prompt, so the
/// same tool set in a different declaration order is a different prefix: the
/// cached KV blocks no longer match and the whole prompt is re-prefilled.
/// Sorting by (name, description, schema) makes equal tool sets share one
/// prefix regardless of registration order. Only the wire order changes —
/// host execution and registration are untouched, and tools are addressed by
/// name, never by index.
pub fn canonical_tool_order(
  tools : Array[@posoco.ToolDef],
) -> Array[@posoco.ToolDef] {
  let ordered = tools.copy()
  ordered.sort_by((a, b) => {
    let by_name = a.name.to_string().compare(b.name.to_string())
    if by_name != 0 {
      by_name
    } else {
      let by_description = a.description.compare(b.description)
      if by_description != 0 {
        by_description
      } else {
        a.input_schema.stringify().compare(b.input_schema.stringify())
      }
    }
  })
  ordered
}
