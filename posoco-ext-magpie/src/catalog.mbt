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
  /// The original Magpie JSON entry, verbatim.
  raw : Json
} derive(Debug)

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
  // A present `reasoning` flag must be a boolean; its absence advertises
  // nothing on its own.
  match fields.get("reasoning") {
    None => ()
    Some(Json::True) | Some(Json::False) => ()
    Some(_) =>
      raise MagpieGatewayError::InvalidResponse(
        "/v1/models: \{where_} field \"reasoning\" must be a boolean",
      )
  }
  let context_window = optional_int(fields, "context_window", where_)
  let capabilities = decode_modalities(fields, where_)
  let efforts = decode_efforts(fields, where_)
  {
    info: {
      model_id: id,
      label: display_name,
      provider_id: owned_by,
      context_window,
      capabilities,
      efforts,
      default_effort: None,
      display_group: None,
    },
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

///|
/// Input modalities beyond plain text become capability identifiers, in
/// server order (`{"input":["text","image"]}` → `["image"]`). Absent
/// modalities mean nothing is claimed.
fn decode_modalities(
  fields : Map[String, Json],
  where_ : String,
) -> Array[String] raise MagpieGatewayError {
  let capabilities : Array[String] = []
  match fields.get("modalities") {
    None => ()
    Some(Json::Object(modalities)) =>
      match modalities.get("input") {
        None => ()
        Some(Json::Array(inputs)) =>
          for input in inputs {
            guard input is Json::String(modality) else {
              raise MagpieGatewayError::InvalidResponse(
                "/v1/models: \{where_} modalities.input must hold strings",
              )
            }
            if modality != "text" {
              capabilities.push(modality)
            }
          }
        Some(_) =>
          raise MagpieGatewayError::InvalidResponse(
            "/v1/models: \{where_} modalities.input must be an array",
          )
      }
    Some(_) =>
      raise MagpieGatewayError::InvalidResponse(
        "/v1/models: \{where_} modalities must be an object",
      )
  }
  capabilities
}

///|
/// Advertised reasoning efforts, in server order, from
/// `supported_reasoning_levels` (`[{"effort":"low"}, …]`). Absent levels
/// mean no effort is advertised — never an invented one. A `reasoning`
/// flag alone advertises nothing.
fn decode_efforts(
  fields : Map[String, Json],
  where_ : String,
) -> Array[String] raise MagpieGatewayError {
  let efforts : Array[String] = []
  match fields.get("supported_reasoning_levels") {
    None => ()
    Some(Json::Array(levels)) =>
      for level in levels {
        guard level is Json::Object(level_fields) else {
          raise MagpieGatewayError::InvalidResponse(
            "/v1/models: \{where_} supported_reasoning_levels must hold objects",
          )
        }
        guard level_fields.get("effort") is Some(Json::String(effort)) else {
          raise MagpieGatewayError::InvalidResponse(
            "/v1/models: \{where_} reasoning level needs a string \"effort\"",
          )
        }
        efforts.push(effort)
      }
    Some(_) =>
      raise MagpieGatewayError::InvalidResponse(
        "/v1/models: \{where_} supported_reasoning_levels must be an array",
      )
  }
  efforts
}
