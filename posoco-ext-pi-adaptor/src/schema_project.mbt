///|
/// Pi/TypeBox tool schemas are JSON Schema documents. Posoco 0.24.2 validates
/// the 2020-12 vocabulary, including composition, numeric bounds and unions.
/// Preserve schemas instead of silently weakening their constraints.
///
/// Unsupported keywords and invalid schemas must be rejected at Posoco's
/// catalog validation boundary; this adapter does not invent a second schema
/// validator. Keeping a named function leaves room for an explicit, tested
/// TypeBox-specific normalization if an actual incompatibility is found.
fn project_tool_schema(schema : Json) -> Json {
  schema
}

///|
/// Keep host-facing catalog projections identical to ToolDef input schemas.
/// Only the "parameters" node is a tool schema; no other catalog metadata
/// should be modified by this adapter.
fn project_catalog_json(value : Json) -> Json {
  value
}
