///|
/// metadata.mbt — typed Magpie-specific catalog metadata.
///
/// The neutral `ManagerModelInfo` projection stays manager-generic; this
/// layer keeps everything Magpie actually declares about a model, with the
/// unknown-versus-declared distinction preserved: every optional field is
/// an `Option`, where `None` means the catalog did not declare it. Fields
/// the neutral contract does not carry are still available verbatim on
/// `MagpieCatalogEntry.raw`, so unknown extension metadata is never lost.

///|
/// The three execution protocols this control plane can plan for. Protocol
/// identities are fixed; which endpoint serves them for a given model is
/// catalog evidence, never assumed.
pub(all) enum MagpieProtocol {
  /// Anthropic Messages (`/v1/messages`).
  Messages
  /// OpenAI Responses (`/v1/responses`).
  Responses
  /// OpenAI Chat Completions (`/v1/chat/completions`).
  ChatCompletions
} derive(Eq, Debug)

///|
pub extend MagpieProtocol with Eq::{not_equal, equal}

///|
pub extend MagpieProtocol with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpieProtocol with fn to_string(self : MagpieProtocol) -> String {
  match self {
    Messages => "Messages"
    Responses => "Responses"
    ChatCompletions => "ChatCompletions"
  }
}

///|
pub extend MagpieProtocol with Show::{to_string, output}

///|
/// One declared native endpoint. `protocol` is `None` for paths this
/// control plane does not recognize — they are retained verbatim, never
/// dropped and never guessed into a protocol.
pub(all) struct MagpieNativeEndpoint {
  protocol : MagpieProtocol?
  path : String
} derive(Eq, Debug)

///|
pub extend MagpieNativeEndpoint with Eq::{not_equal, equal}

///|
pub extend MagpieNativeEndpoint with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Typed Magpie metadata for one catalog entry.
///
/// `is_routing_group` reflects Magpie's `group/` id namespace: such ids
/// resolve their upstream members at request time, so no native protocol
/// claim can be extended to them, whatever the catalog declares.
pub(all) struct MagpieModelMetadata {
  /// Opaque catalog id, verbatim; never split, parsed, or assumed to have
  /// exactly one slash.
  model_id : String
  display_name : String
  /// Magpie's presentation label, when the catalog declares one.
  magpie_label : String?
  /// Provider attribution (`owned_by`).
  provider_id : String
  /// `true` when the id lives in Magpie's `group/` namespace.
  is_routing_group : Bool
  context_window : Int32?
  context_length : Int32?
  max_input_tokens : Int32?
  max_output_tokens : Int32?
  /// Declared input modalities, in server order; `None` = not declared.
  modalities_input : Array[String]?
  /// Declared reasoning support; `None` = not declared.
  reasoning_declared : Bool?
  /// Advertised effort names, exact strings in server order; `None` = the
  /// field is absent (an empty array means declared-but-empty).
  reasoning_levels : Array[String]?
  /// Declared native endpoints, in server order; `None` = the field is
  /// absent (an empty array means declared-but-empty).
  native_endpoints : Array[MagpieNativeEndpoint]?
} derive(Eq, Debug)

///|
pub extend MagpieModelMetadata with Eq::{not_equal, equal}

///|
pub extend MagpieModelMetadata with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// First item matching `pred`, `None` when nothing matches. The package
/// uses this helper everywhere it would otherwise reach for `Iter::find`.
fn[T] find_first(items : Iter[T], pred : (T) -> Bool) -> T? {
  for item in items {
    if pred(item) {
      return Some(item)
    }
  }
  None
}

///|
/// The declared native endpoint path for `protocol`, when the metadata
/// declares one.
pub fn MagpieModelMetadata::native_path_for(
  self : MagpieModelMetadata,
  protocol : MagpieProtocol,
) -> String? {
  guard self.native_endpoints is Some(endpoints) else { return None }
  match
    find_first(endpoints.iter(), fn(endpoint) {
      endpoint.protocol == Some(protocol)
    }) {
    Some(endpoint) => Some(endpoint.path)
    None => None
  }
}

///|
/// Parses one endpoint path into a typed native endpoint. The three known
/// protocol paths map to their protocols; anything else is retained with
/// `protocol = None`.
pub fn parse_native_endpoint(path : String) -> MagpieNativeEndpoint {
  let protocol = if path is "/v1/messages" {
    Some(Messages)
  } else if path is "/v1/responses" {
    Some(Responses)
  } else if path is "/v1/chat/completions" {
    Some(ChatCompletions)
  } else {
    None
  }
  { protocol, path, }
}

///|
/// Decodes typed metadata from one raw catalog entry. Strict for the fields
/// this layer types (present-but-wrong is malformed, matching the catalog
/// contract); silent for everything else, which stays on `raw`.
pub fn decode_model_metadata(
  model_id~ : String,
  display_name~ : String,
  provider_id~ : String,
  fields : Map[String, Json],
  where_ : String,
) -> MagpieModelMetadata raise MagpieGatewayError {
  let magpie_label = match fields.get("magpie_label") {
    None => None
    Some(Json::String(label)) => Some(label)
    Some(_) =>
      raise MagpieGatewayError::InvalidResponse(
        "/v1/models: \{where_} field \"magpie_label\" must be a string",
      )
  }
  let context_length = optional_int(fields, "context_length", where_)
  let max_input_tokens = optional_int(fields, "max_input_tokens", where_)
  let max_output_tokens = optional_int(fields, "max_output_tokens", where_)
  let modalities_input = decode_modalities_input(fields, where_)
  let reasoning_declared = match fields.get("reasoning") {
    None => None
    Some(Json::True) => Some(true)
    Some(Json::False) => Some(false)
    Some(_) =>
      raise MagpieGatewayError::InvalidResponse(
        "/v1/models: \{where_} field \"reasoning\" must be a boolean",
      )
  }
  let reasoning_levels = match fields.get("supported_reasoning_levels") {
    None => None
    Some(Json::Array(levels)) => {
      let efforts : Array[String] = []
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
      Some(efforts)
    }
    Some(_) =>
      raise MagpieGatewayError::InvalidResponse(
        "/v1/models: \{where_} supported_reasoning_levels must be an array",
      )
  }
  let native_endpoints = match fields.get("native_endpoints") {
    None => None
    Some(Json::Array(paths)) => {
      let endpoints : Array[MagpieNativeEndpoint] = []
      for path in paths {
        guard path is Json::String(text) else {
          raise MagpieGatewayError::InvalidResponse(
            "/v1/models: \{where_} native_endpoints must hold strings",
          )
        }
        if text is "" {
          raise MagpieGatewayError::InvalidResponse(
            "/v1/models: \{where_} native_endpoints has an empty path",
          )
        }
        endpoints.push(parse_native_endpoint(text))
      }
      Some(endpoints)
    }
    Some(_) =>
      raise MagpieGatewayError::InvalidResponse(
        "/v1/models: \{where_} native_endpoints must be an array",
      )
  }
  {
    model_id,
    display_name,
    magpie_label,
    provider_id,
    is_routing_group: model_id.has_prefix("group/"),
    context_window: optional_int(fields, "context_window", where_),
    context_length,
    max_input_tokens,
    max_output_tokens,
    modalities_input,
    reasoning_declared,
    reasoning_levels,
    native_endpoints,
  }
}

///|
/// Declared input modalities, in server order; `None` = field absent.
/// Malformed shapes are rejected; unknown modality names are retained.
fn decode_modalities_input(
  fields : Map[String, Json],
  where_ : String,
) -> Array[String]? raise MagpieGatewayError {
  match fields.get("modalities") {
    None => None
    Some(Json::Object(modalities)) =>
      match modalities.get("input") {
        None => Some([])
        Some(Json::Array(inputs)) => {
          let names : Array[String] = []
          for input in inputs {
            guard input is Json::String(modality) else {
              raise MagpieGatewayError::InvalidResponse(
                "/v1/models: \{where_} modalities.input must hold strings",
              )
            }
            names.push(modality)
          }
          Some(names)
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
}
