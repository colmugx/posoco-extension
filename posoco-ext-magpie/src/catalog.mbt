///|
/// catalog.mbt — pure `/v1/models` decoding and neutral projection.
///
/// The decoder is a pure function from a response body to a catalog report:
/// no transport, no state. It is strict where Magpie's catalog contract is
/// strict and honest where the gateway may omit facts — an absent context
/// window stays unknown, an absent reasoning declaration advertises no
/// efforts, and nothing is ever fabricated or defaulted.

///|

///|
pub extend MagpieCatalogEntry with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One decoded catalog model: the manager-neutral projection hosts select
/// through, plus the raw Magpie entry preserved verbatim for anything the
/// neutral contract does not carry (e.g. `magpie_label`,
/// `max_output_tokens`, `native_endpoints`). Catalog objects never contain
/// gateway credentials.
pub(all) struct MagpieCatalogEntry {
  /// Manager-neutral projection (`ManagerModelInfo`).
  info : @modelmgmt.ManagerModelInfo
  /// Typed Magpie-specific metadata (labels, context limits, modalities,
  /// reasoning declaration, native endpoints, routing-group identity).
  meta : MagpieModelMetadata
  /// The original Magpie JSON entry, verbatim; unknown extension metadata
  /// stays available here.
  raw : Json
} derive(Debug)

///|
pub extend MagpieCatalogReport with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Result of decoding one `/v1/models` payload: the deduplicated catalog in
/// server order, plus the ids that appeared more than once. Duplicates are
/// surfaced explicitly; the first occurrence wins.
pub(all) struct MagpieCatalogReport {
  /// Decoded entries in server order — stable and deterministic.
  entries : Array[MagpieCatalogEntry]
  /// Ids seen more than once, in first-duplicate order.
  duplicates : Array[String]
} derive(Debug)

///|
/// Decodes a `/v1/models` body. Raises `MagpieGatewayError::InvalidResponse`
/// for unparsable JSON, a non-object payload, a missing `data` array, or an
/// entry whose present fields do not match the documented shapes.
pub fn decode_catalog(
  body : String,
) -> MagpieCatalogReport raise MagpieGatewayError {
  let value = @json.parse(body) catch {
    _ => raise MagpieGatewayError::InvalidResponse("/v1/models: invalid JSON")
  }
  guard value is Json::Object(root) else {
    raise MagpieGatewayError::InvalidResponse(
      "/v1/models: expected a JSON object",
    )
  }
  guard root.get("data") is Some(Json::Array(data)) else {
    raise MagpieGatewayError::InvalidResponse(
      "/v1/models: missing \"data\" array",
    )
  }
  let entries : Array[MagpieCatalogEntry] = []
  let duplicates : Array[String] = []
  let seen : Map[String, Bool] = Map::from_array([])
  for index, item in data {
    let entry = decode_entry(item, index)
    let id = entry.info.model_id
    if seen.contains(id) {
      duplicates.push(id)
    } else {
      seen[id] = true
      entries.push(entry)
    }
  }
  { entries, duplicates, }
}

///|
fn decode_entry(
  item : Json,
  index : Int32,
) -> MagpieCatalogEntry raise MagpieGatewayError {
  let where_ = "entry[\{index}]"
  guard item is Json::Object(fields) else {
    raise MagpieGatewayError::InvalidResponse(
      "/v1/models: \{where_} is not an object",
    )
  }
  let id = required_string(fields, "id", where_)
  let where_ = "entry[\{index}] (\{id})"
  let display_name = required_string(fields, "display_name", where_)
  let owned_by = required_string(fields, "owned_by", where_)
  let meta = decode_model_metadata(
    model_id=id,
    display_name~,
    provider_id=owned_by,
    fields,
    where_,
  )
  // The neutral projection is derived from the typed metadata, so both
  // layers always agree. Absent declarations stay honest: no fabricated
  // defaults, no invented grouping.
  let capabilities = match meta.modalities_input {
    Some(inputs) => inputs.filter(fn(modality) { modality != "text" })
    None => []
  }
  let efforts = match meta.reasoning_levels {
    Some(levels) => levels
    None => []
  }
  {
    info: {
      model_id: id,
      label: display_name,
      provider_id: owned_by,
      context_window: meta.context_window,
      capabilities,
      efforts,
      default_effort: None,
      display_group: None,
    },
    meta,
    raw: item,
  }
}

///|
/// A required string field: absent, non-string, or empty is malformed.
fn required_string(
  fields : Map[String, Json],
  key : String,
  where_ : String,
) -> String raise MagpieGatewayError {
  guard fields.get(key) is Some(Json::String(text)) else {
    raise MagpieGatewayError::InvalidResponse(
      "/v1/models: \{where_} needs a string \"\{key}\"",
    )
  }
  if text is "" {
    raise MagpieGatewayError::InvalidResponse(
      "/v1/models: \{where_} has an empty \"\{key}\"",
    )
  }
  text
}

///|
/// An optional integer field. Absent stays unknown — never a fabricated
/// default. Present but not a whole number in `Int` range is malformed.
fn optional_int(
  fields : Map[String, Json],
  key : String,
  where_ : String,
) -> Int32? raise MagpieGatewayError {
  match fields.get(key) {
    None => None
    Some(Json::Number(value, ..)) => {
      let whole = value.to_int()
      if value != whole.to_double() {
        raise MagpieGatewayError::InvalidResponse(
          "/v1/models: \{where_} field \"\{key}\" must be a whole number",
        )
      }
      Some(whole)
    }
    Some(_) =>
      raise MagpieGatewayError::InvalidResponse(
        "/v1/models: \{where_} field \"\{key}\" must be a number",
      )
  }
}
