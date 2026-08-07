///|
/// Machine state for a project-local handoff.
pub(all) enum HandoffStatus {
  Offered
  Active
  Rejected
  Cancelled
} derive(Eq, Debug)

///|
pub fn HandoffStatus::to_wire(self : HandoffStatus) -> String {
  match self {
    Offered => "offered"
    Active => "active"
    Rejected => "rejected"
    Cancelled => "cancelled"
  }
}

///|
fn handoff_status_from_wire(value : String) -> HandoffStatus? {
  match value {
    "offered" => Some(Offered)
    "active" => Some(Active)
    "rejected" => Some(Rejected)
    "cancelled" => Some(Cancelled)
    _ => None
  }
}

///|
/// Deterministic workspace facts captured by the host. `signature` must be
/// stable for semantically identical workspace state and must exclude the
/// `.handoff/` directory itself.
pub(all) struct WorkspaceSnapshot {
  root : String
  branch : String?
  head : String?
  signature : String
  changed_files : Array[String]
} derive(Eq, Debug)

///|
/// Semantic work facts supplied explicitly by the operator or another
/// deterministic host source. Missing values stay missing; this extension
/// never asks an LLM to infer them.
pub(all) struct WorkSnapshot {
  objective : String?
  current_step : String?
  next_action : String?
  completed : Array[String]
  pending : Array[String]
  validation_passed : Array[String]
  validation_failed : Array[String]
  validation_not_run : Array[String]
} derive(Eq, Debug)

///|
pub fn WorkSnapshot::empty() -> WorkSnapshot {
  {
    objective: None,
    current_step: None,
    next_action: None,
    completed: [],
    pending: [],
    validation_passed: [],
    validation_failed: [],
    validation_not_run: [],
  }
}

///|
/// The authoritative machine-readable state persisted in
/// `.handoff/state.json`.
pub(all) struct HandoffState {
  version : Int
  generation : Int
  id : String
  status : HandoffStatus
  source_session_id : String
  target_session_id : String?
  rejected_by_session_id : String?
  rejection_reason : String?
  workspace : WorkspaceSnapshot
  work : WorkSnapshot
} derive(Eq, Debug)

///|
/// Host-owned workspace adapter. Keeping Git/process discovery behind this
/// seam makes the handoff protocol target-agnostic and easy to fake in tests.
pub(open) trait HandoffWorkspaceProbe {
  fn snapshot(Self, cwd : String) -> Result[WorkspaceSnapshot, String]
}

///|
fn string_array_to_json(values : Array[String]) -> Json {
  let result : Array[Json] = []
  for value in values {
    result.push(Json::string(value))
  }
  Json::array(result)
}

///|
fn optional_string_field(fields : Array[(String, Json)], key : String, value : String?) -> Unit {
  match value {
    Some(text) => fields.push((key, Json::string(text)))
    None => ()
  }
}

///|
fn workspace_to_json(workspace : WorkspaceSnapshot) -> Json {
  let fields : Array[(String, Json)] = [
    ("root", Json::string(workspace.root)),
    ("signature", Json::string(workspace.signature)),
    ("changed_files", string_array_to_json(workspace.changed_files)),
  ]
  optional_string_field(fields, "branch", workspace.branch)
  optional_string_field(fields, "head", workspace.head)
  Json::object(Map::from_array(fields))
}

///|
fn work_to_json(work : WorkSnapshot) -> Json {
  let fields : Array[(String, Json)] = [
    ("completed", string_array_to_json(work.completed)),
    ("pending", string_array_to_json(work.pending)),
    ("validation_passed", string_array_to_json(work.validation_passed)),
    ("validation_failed", string_array_to_json(work.validation_failed)),
    ("validation_not_run", string_array_to_json(work.validation_not_run)),
  ]
  optional_string_field(fields, "objective", work.objective)
  optional_string_field(fields, "current_step", work.current_step)
  optional_string_field(fields, "next_action", work.next_action)
  Json::object(Map::from_array(fields))
}

///|
pub fn HandoffState::to_json(self : HandoffState) -> Json {
  let fields : Array[(String, Json)] = [
    ("version", Json::number(self.version.to_double())),
    ("generation", Json::number(self.generation.to_double())),
    ("id", Json::string(self.id)),
    ("status", Json::string(self.status.to_wire())),
    ("source_session_id", Json::string(self.source_session_id)),
    ("workspace", workspace_to_json(self.workspace)),
    ("work", work_to_json(self.work)),
  ]
  optional_string_field(fields, "target_session_id", self.target_session_id)
  optional_string_field(
    fields,
    "rejected_by_session_id",
    self.rejected_by_session_id,
  )
  optional_string_field(fields, "rejection_reason", self.rejection_reason)
  Json::object(Map::from_array(fields))
}

///|
pub fn HandoffState::stringify(self : HandoffState) -> String {
  self.to_json().stringify()
}

///|
fn require_object(value : Json, path : String) -> Result[Map[String, Json], String] {
  match value {
    Json::Object(fields) => Ok(fields)
    _ => Err(path + " must be an object")
  }
}

///|
fn required_string(fields : Map[String, Json], key : String, path : String) -> Result[String, String] {
  if !fields.contains(key) {
    return Err(path + "." + key + " is required")
  }
  match fields[key] {
    Json::String(value) => Ok(value)
    _ => Err(path + "." + key + " must be a string")
  }
}

///|
fn optional_string(fields : Map[String, Json], key : String, path : String) -> Result[String?, String] {
  if !fields.contains(key) {
    return Ok(None)
  }
  match fields[key] {
    Json::String(value) => Ok(Some(value))
    _ => Err(path + "." + key + " must be a string")
  }
}

///|
fn required_int(fields : Map[String, Json], key : String, path : String) -> Result[Int, String] {
  if !fields.contains(key) {
    return Err(path + "." + key + " is required")
  }
  match fields[key] {
    Json::Number(value) => Ok(value.to_int())
    _ => Err(path + "." + key + " must be a number")
  }
}

///|
fn string_array(fields : Map[String, Json], key : String, path : String) -> Result[Array[String], String] {
  if !fields.contains(key) {
    return Ok([])
  }
  match fields[key] {
    Json::Array(values) => {
      let result : Array[String] = []
      for value in values {
        match value {
          Json::String(text) => result.push(text)
          _ => return Err(path + "." + key + " must contain only strings")
        }
      }
      Ok(result)
    }
    _ => Err(path + "." + key + " must be an array")
  }
}

///|
fn workspace_from_json(value : Json) -> Result[WorkspaceSnapshot, String] {
  let fields = match require_object(value, "workspace") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let root = match required_string(fields, "root", "workspace") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let signature = match required_string(fields, "signature", "workspace") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let branch = match optional_string(fields, "branch", "workspace") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let head = match optional_string(fields, "head", "workspace") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let changed_files = match string_array(fields, "changed_files", "workspace") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  Ok({ root, branch, head, signature, changed_files })
}

///|
fn work_from_json(value : Json) -> Result[WorkSnapshot, String] {
  let fields = match require_object(value, "work") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let objective = match optional_string(fields, "objective", "work") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let current_step = match optional_string(fields, "current_step", "work") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let next_action = match optional_string(fields, "next_action", "work") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let completed = match string_array(fields, "completed", "work") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let pending = match string_array(fields, "pending", "work") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let validation_passed = match string_array(fields, "validation_passed", "work") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let validation_failed = match string_array(fields, "validation_failed", "work") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let validation_not_run = match string_array(fields, "validation_not_run", "work") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  Ok({
    objective,
    current_step,
    next_action,
    completed,
    pending,
    validation_passed,
    validation_failed,
    validation_not_run,
  })
}

///|
pub fn handoff_state_from_json(value : Json) -> Result[HandoffState, String] {
  let fields = match require_object(value, "handoff") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let version = match required_int(fields, "version", "handoff") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let generation = match required_int(fields, "generation", "handoff") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let id = match required_string(fields, "id", "handoff") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let status_text = match required_string(fields, "status", "handoff") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let status = match handoff_status_from_wire(status_text) {
    Some(value) => value
    None => return Err("handoff.status is unknown: " + status_text)
  }
  let source_session_id = match required_string(fields, "source_session_id", "handoff") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let target_session_id = match optional_string(fields, "target_session_id", "handoff") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let rejected_by_session_id = match optional_string(fields, "rejected_by_session_id", "handoff") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let rejection_reason = match optional_string(fields, "rejection_reason", "handoff") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if !fields.contains("workspace") {
    return Err("handoff.workspace is required")
  }
  let workspace = match workspace_from_json(fields["workspace"]) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if !fields.contains("work") {
    return Err("handoff.work is required")
  }
  let work = match work_from_json(fields["work"]) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  Ok({
    version,
    generation,
    id,
    status,
    source_session_id,
    target_session_id,
    rejected_by_session_id,
    rejection_reason,
    workspace,
    work,
  })
}
