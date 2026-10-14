///|
/// hello.mbt — `/api/hello` identity validation.
///
/// Magpie answers `GET /api/hello` with `{"name":"magpie","version":"…"}`.
/// Validating that identity before decoding the catalog is what lets the
/// manager say "this is not Magpie" instead of misparsing some other
/// service's model list.

///|
/// Self-reported identity of a Magpie gateway.
pub(all) struct MagpieIdentity {
  /// Service name; Magpie reports `"magpie"`.
  name : String
  /// Gateway version, when the payload names one.
  version : String?
} derive(Eq, Debug)

///|
pub extend MagpieIdentity with Eq::{not_equal, equal}

///|
pub extend MagpieIdentity with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Parses and validates a `/api/hello` body. Raises `InvalidResponse` for
/// unparsable or wrongly shaped payloads and `WrongIdentity` when the
/// endpoint names any service other than `magpie`.
pub fn parse_hello(body : String) -> MagpieIdentity raise MagpieGatewayError {
  let value = @json.parse(body) catch {
    _ => raise MagpieGatewayError::InvalidResponse("/api/hello: invalid JSON")
  }
  guard value is Json::Object(fields) else {
    raise MagpieGatewayError::InvalidResponse(
      "/api/hello: expected a JSON object",
    )
  }
  guard fields.get("name") is Some(Json::String(name)) else {
    raise MagpieGatewayError::InvalidResponse(
      "/api/hello: missing string field \"name\"",
    )
  }
  if name != "magpie" {
    raise MagpieGatewayError::WrongIdentity(
      "/api/hello: service identifies itself as \"\{name}\", not \"magpie\"",
    )
  }
  let version = match fields.get("version") {
    Some(Json::String(v)) => Some(v)
    Some(_) =>
      raise MagpieGatewayError::InvalidResponse(
        "/api/hello: field \"version\" must be a string when present",
      )
    None => None
  }
  { name, version, }
}
