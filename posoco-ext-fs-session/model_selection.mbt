///|
/// model_selection.mbt — session-scoped record of the last model selection.
///
/// The store subscribes to the ext-llm `model_selection` bus event and
/// decorates every persisted metadata line with the selection observed at
/// write time, so a session file remembers which slot/effort produced its
/// transcript tail. Hosts read it back through `summary()` (or
/// `model_selection_from_metadata`) and restore the selection on resume.
///
/// Semantics: the metadata records the selection at the moment of the last
/// persist — the model that produced the transcript's tail. A switch that is
/// never followed by a persist is not recorded. Stores composed without a
/// bus never observe anything and never decorate, so legacy journals and
/// plain-library uses are untouched.

///|
/// V2 selection metadata is owner-qualified. The legacy `slot_id` value
/// is never interpreted as a manager-neutral model id.
pub const MODEL_SELECTION_V2_METADATA_KEY : String = "posoco.model_selection_v2"

///|
pub(all) struct SessionSelectionV2 {
  owner : String
  model_id : String
  effort : String?
  pending : Bool
  revision : Int64
} derive(Eq, Debug)

///|
pub extend SessionSelectionV2 with Eq::{not_equal, equal}

///|
pub extend SessionSelectionV2 with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn session_selection_v2_to_json(value : SessionSelectionV2) -> Json {
  Json::object(
    Map::from_array([
      ("version", Json::number(2)),
      ("owner", Json::string(value.owner)),
      ("model_id", Json::string(value.model_id)),
      (
        "effort",
        match value.effort {
          Some(effort) => Json::string(effort)
          None => Json::null()
        },
      ),
      ("pending", Json::boolean(value.pending)),
      ("revision", Json::string(value.revision.to_string())),
    ]),
  )
}

///|
/// Version and owner must be explicit: invalid v2 never silently becomes
/// an ext-llm or ext-magpie selection.
pub fn session_selection_v2_from_json(value : Json) -> SessionSelectionV2? {
  guard value is Json::Object(fields) else { return None }
  guard fields.get("version") is Some(Json::Number(version, ..)) &&
    version == 2.0 &&
    fields.get("owner") is Some(Json::String(owner)) &&
    !owner.is_empty() &&
    fields.get("model_id") is Some(Json::String(model_id)) &&
    !model_id.is_empty() else {
    return None
  }
  let effort = match fields.get("effort") {
    None | Some(Json::Null) => None
    Some(Json::String(v)) => Some(v)
    _ => return None
  }
  let pending = match fields.get("pending") {
    Some(Json::True) => true
    Some(Json::False) => false
    _ => return None
  }
  guard fields.get("revision") is Some(Json::String(revision_text)) else {
    return None
  }
  let revision : Int64 = @string.parse_int64(revision_text) catch {
    _ => return None
  }
  if revision < 0L {
    return None
  }
  Some({ owner, model_id, effort, pending, revision, })
}

///|
pub fn session_selection_v2_from_metadata(
  metadata : Map[String, Json],
) -> SessionSelectionV2? {
  match metadata.get(MODEL_SELECTION_V2_METADATA_KEY) {
    Some(value) => session_selection_v2_from_json(value)
    None => None
  }
}

///|
/// Owner-mismatched sessions must not select a same-named model from an
/// unrelated manager. Legacy records are deliberately not part of this API.
pub fn session_selection_v2_for_owner(
  metadata : Map[String, Json],
  owner : String,
) -> SessionSelectionV2? {
  match session_selection_v2_from_metadata(metadata) {
    Some(selection) if selection.owner == owner => Some(selection)
    _ => None
  }
}

///|

///|
/// Injected by the host at a successful manager-selection boundary.
/// The store cannot infer ownership from a model name or a provider prefix.
pub fn JsonlSessionStore::observe_selection_v2(
  self : JsonlSessionStore,
  selection : SessionSelectionV2,
) -> Unit {
  if selection.owner.is_empty() ||
    selection.model_id.is_empty() ||
    selection.revision < 0L {
    return
  }
  self.observed_selection_v2 = Some(selection)
}

///|
fn metadata_with_observed_selection_v2(
  metadata : Map[String, Json],
  selection : SessionSelectionV2?,
) -> Map[String, Json] {
  match selection {
    Some(value) => metadata_with_selection_v2(metadata, value)
    None => metadata
  }
}

///|
/// Restore lookup is owner-qualified. Reading alone never changes an active
/// manager or an Agent; the host resolves the returned selection through its
/// currently bound ModelManagerControl, with no id-name guessing.
pub async fn JsonlSessionStore::selection_for_owner(
  self : JsonlSessionStore,
  session_id : String,
  owner : String,
) -> @modelmgmt.SelectionRef? raise @posoco.SessionError {
  let session = self.load(session_id)
  match session_selection_v2_for_owner(session.metadata, owner) {
    Some(value) =>
      Some({
        owner: value.owner,
        model_id: value.model_id,
        effort: value.effort,
        pending: value.pending,
        revision: value.revision,
      })
    None => None
  }
}

///|
/// Convert the neutral Manager's committed selection into the versioned
/// session payload; no concrete Router/Gateway type is inspected.
pub fn session_selection_v2_of(
  value : @modelmgmt.SelectionRef,
) -> SessionSelectionV2? {
  if !value.valid() {
    return None
  }
  Some({
    owner: value.owner,
    model_id: value.model_id,
    effort: value.effort,
    pending: value.pending,
    revision: value.revision,
  })
}

///|
/// Rewrites only metadata line 1; preserves message lines byte-for-byte.
pub fn rewrite_metadata_line_v2(
  content : String,
  selection : SessionSelectionV2?,
) -> String? {
  guard selection is Some(value) else { return None }
  let parts : Array[String] = []
  for part in content.split("\n") {
    parts.push(part.to_owned())
  }
  if parts.length() < 2 {
    return None
  }
  let parsed : Result[Json, Error] = Ok(@json.parse(parts[0])) catch {
    e => Err(e)
  }
  let metadata : Map[String, Json] = match parsed {
    Ok(Json::Object(fields)) => fields
    _ => return None
  }
  metadata[MODEL_SELECTION_V2_METADATA_KEY] = session_selection_v2_to_json(
    value,
  )
  let buf = StringBuilder()
  buf.write_string(Json::object(metadata).stringify())
  for i in 1..<parts.length() {
    buf.write_char('\n')
    buf.write_string(parts[i])
  }
  Some(buf.to_string())
}

///|
pub fn metadata_with_selection_v2(
  metadata : Map[String, Json],
  selection : SessionSelectionV2,
) -> Map[String, Json] {
  let result = metadata.copy()
  result[MODEL_SELECTION_V2_METADATA_KEY] = session_selection_v2_to_json(
    selection,
  )
  result
}

///|
/// Metadata key written by this store. Value shape:
/// `{"slot_id": "<router slot id>", "effort": "<effort>" | null}` where
/// `slot_id` matches the router's persisted-selection vocabulary
/// (`ActiveModelSelection.slot`) and a null/absent effort means slot default.
pub const MODEL_SELECTION_METADATA_KEY : String = "posoco.model_selection"

///|
/// Source filter for the observed events: only the ext-llm router's
/// `model_selection` topic is recorded.
fn is_model_selection_event(event : @devkit.BusEvent) -> Bool {
  event.source == "posoco_ext_llm" && event.topic == "model_selection"
}

///|
/// JSON payload for one recorded selection.
fn selection_metadata_json(slot : String, effort : String?) -> Json {
  Json::object(
    Map::from_array([
      ("slot_id", Json::string(slot)),
      (
        "effort",
        match effort {
          Some(value) => Json::string(value)
          None => Json::null()
        },
      ),
    ]),
  )
}

///|
/// Parse a `model_selection` payload: `{"slot_id": "...", "effort": "..." |
/// null}`. Anything else — wrong shape, empty slot id — returns `None`.
fn selection_from_payload(data : Json) -> (String, String?)? {
  match data {
    Json::Object(fields) =>
      match fields.get("slot_id") {
        Some(Json::String(slot)) if !slot.is_empty() => {
          let effort = match fields.get("effort") {
            Some(Json::String(value)) => Some(value)
            _ => None
          }
          Some((slot, effort))
        }
        _ => None
      }
    _ => None
  }
}

///|
/// Read a recorded selection back out of session metadata. Absent or
/// malformed payloads return `None` (legacy journals, stores without the
/// model bus).
pub fn model_selection_from_metadata(
  metadata : Map[String, Json],
) -> (String, String?)? {
  match metadata.get(MODEL_SELECTION_METADATA_KEY) {
    Some(data) => selection_from_payload(data)
    None => None
  }
}

///|
/// Copy `metadata` and inject the recorded selection. A `None` selection (no
/// bus, no event observed yet) returns the metadata untouched so legacy
/// journals are never decorated by accident.
fn metadata_with_selection(
  metadata : Map[String, Json],
  selection : (String, String?)?,
) -> Map[String, Json] {
  match selection {
    None => metadata
    Some((slot, effort)) => {
      let decorated : Map[String, Json] = Map::from_array([])
      for key, value in metadata {
        decorated[key] = value
      }
      decorated[MODEL_SELECTION_METADATA_KEY] = selection_metadata_json(
        slot, effort,
      )
      decorated
    }
  }
}

///|
/// Rewrite only the metadata line of a persisted journal so a freshly
/// observed selection is recorded without disturbing appended history or a
/// torn final line. `None` means the content has no recognizable metadata
/// line (no line break, parse failure, non-object) and the caller should
/// leave the file untouched; the next full save decorates from scratch.
pub fn rewrite_metadata_line(
  content : String,
  selection : (String, String?)?,
) -> String? {
  let (slot, effort) = match selection {
    Some(pair) => pair
    None => return None
  }
  let parts : Array[String] = []
  for part in content.split("\n") {
    parts.push(part.to_owned())
  }
  if parts.length() < 2 {
    return None
  }
  let metadata_parse : Result[Json, Error] = Ok(@json.parse(parts[0])) catch {
    e => Err(e)
  }
  let metadata : Map[String, Json] = match metadata_parse {
    Ok(Json::Object(fields)) => fields
    _ => return None
  }
  metadata[MODEL_SELECTION_METADATA_KEY] = selection_metadata_json(slot, effort)
  let buf = StringBuilder()
  buf.write_string(Json::object(metadata).stringify())
  for i in 1..<parts.length() {
    buf.write_char('\n')
    buf.write_string(parts[i])
  }
  Some(buf.to_string())
}

///|
/// Observe the ext-llm selection channel. Foreign topics/sources are
/// ignored; a malformed payload keeps the previous observation.
impl @devkit.BusSubscriber for JsonlSessionStore with fn on_bus_event(
  self : JsonlSessionStore,
  event : @devkit.BusEvent,
) -> Unit {
  if is_model_selection_event(event) {
    match selection_from_payload(event.data) {
      Some(pair) => self.observed_selection = Some(pair)
      None => ()
    }
  }
}

///|
/// Register the store on the shared bus so selection changes reach it.
/// Called from the target-specific constructors.
fn JsonlSessionStore::subscribe_model_selection(
  self : JsonlSessionStore,
  bus : @devkit.EventBus?,
) -> Unit {
  match bus {
    Some(bus) => bus.subscribe(self as &@devkit.BusSubscriber)
    None => ()
  }
}

///|
/// Record that the persisted metadata line now reflects `selection`.
fn JsonlSessionStore::mark_selection_written(
  self : JsonlSessionStore,
  selection : (String, String?)?,
) -> Unit {
  self.written_selection = selection
  self.written_selection_v2 = self.observed_selection_v2
}
