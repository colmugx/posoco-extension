///|
/// One string field of a Board task projection, or `""`.
pub fn task_field(task : Json, key : String) -> String {
  match task {
    Object(fields) =>
      match fields.get(key) {
        Some(String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
/// The reviewer feedback a Board task carries, or `None`. Blank text reads as
/// absent: the Board rejects empty feedback, so a whitespace body is never a
/// requirement a worker has to address.
pub fn task_review_feedback(task : Json) -> String? {
  match task {
    Object(fields) =>
      match fields.get("review_feedback") {
        Some(String(value)) if !value.trim().is_empty() => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
pub fn task_definition_of_done(task : Json) -> Array[String] {
  match task {
    Object(fields) =>
      match fields.get("definition_of_done") {
        Some(Array(items)) =>
          items.filter_map(item => {
            match item {
              String(text) if text != "" => Some(text)
              _ => None
            }
          })
        _ => []
      }
    _ => []
  }
}

///|
/// The optional pinned model of one Board task. A missing or null model means
/// "inherit the current host selection".
pub(all) struct ModelPin {
  slot : String
  effort : String?
}

///|
pub fn task_model(task : Json) -> ModelPin? {
  let fields = match task {
    Object(fields) => fields
    _ => return None
  }
  let model = match fields.get("model") {
    Some(Object(model)) => model
    _ => return None
  }
  let slot = match model.get("slot") {
    Some(String(value)) if !value.trim().is_empty() => value
    _ => return None
  }
  let effort = match model.get("effort") {
    Some(String(value)) if !value.trim().is_empty() => Some(value)
    _ => None
  }
  Some({ slot, effort, })
}

///|
/// Encode one pinned model for `board.task.set_model`. `None` stays JSON
/// null: "inherit the current selection", never a copied slot.
pub fn model_pin_json(model : ModelPin?) -> Json {
  match model {
    Some(model) =>
      Json::object({
        "slot": Json::string(model.slot),
        "effort": match model.effort {
          Some(effort) => Json::string(effort)
          None => Json::null()
        },
      })
    None => Json::null()
  }
}

///|
/// The authoritative tasks, attempts and revision of one Board snapshot. All
/// three come from the same read, so a decision is never made across a commit.
pub struct BoardState {
  tasks : Array[Json]
  attempts : Array[Json]
  revision : Int64
}

///|
fn snapshot_board(
  snapshot : @board_protocol.BoardSnapshot,
) -> Result[Map[String, Json], String] {
  match snapshot.payload {
    Object(payload) =>
      match payload.get("board") {
        Some(Object(board)) => Ok(board)
        _ => Err("board snapshot has no board object")
      }
    _ => Err("board snapshot payload is invalid")
  }
}

///|
/// Read the full state: a snapshot without an attempts array is malformed for
/// any caller that decides on attempts.
pub fn BoardState::from_snapshot(
  snapshot : @board_protocol.BoardSnapshot,
) -> Result[BoardState, String] {
  let board = match snapshot_board(snapshot) {
    Ok(board) => board
    Err(error) => return Err(error)
  }
  let tasks = match board.get("tasks") {
    Some(Array(tasks)) => tasks
    _ => return Err("board snapshot has no task array")
  }
  let attempts = match board.get("attempts") {
    Some(Array(attempts)) => attempts
    _ => return Err("board snapshot has no attempt array")
  }
  Ok({ tasks, attempts, revision: snapshot.board_revision, })
}

///|
/// Read only the tasks and revision, for callers that never consult attempts.
pub fn BoardState::tasks_from_snapshot(
  snapshot : @board_protocol.BoardSnapshot,
) -> Result[BoardState, String] {
  let board = match snapshot_board(snapshot) {
    Ok(board) => board
    Err(error) => return Err(error)
  }
  let tasks = match board.get("tasks") {
    Some(Array(tasks)) => tasks
    _ => return Err("board snapshot has no task array")
  }
  Ok({ tasks, attempts: [], revision: snapshot.board_revision, })
}

///|
/// One task of the snapshot by id, or `None`.
pub fn BoardState::task(self : BoardState, task_id : String) -> Json? {
  for task in self.tasks {
    if task_field(task, "id") == task_id {
      return Some(task)
    }
  }
  None
}

///|
/// The stage of one task in this snapshot, or `""`.
pub fn BoardState::stage(self : BoardState, task_id : String) -> String {
  match self.task(task_id) {
    Some(task) => task_field(task, "stage")
    None => ""
  }
}

///|
/// Whether another task still depends on the given task.
pub fn BoardState::has_dependents(self : BoardState, task_id : String) -> Bool {
  for task in self.tasks {
    match task {
      Object(fields) =>
        match fields.get("dependencies") {
          Some(Array(dependencies)) =>
            for dependency in dependencies {
              if dependency is String(value) && value == task_id {
                return true
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  false
}

///|
/// The latest Running Review attempt of one task, from the authoritative Board
/// attempts array. A review decision belongs to an attempt, so requesting
/// changes needs the attempt that is under review right now: `None` is a
/// readable "nothing is being reviewed", never a reason to guess an earlier,
/// already-decided attempt. Ties on `created_at_ms` keep the later entry,
/// which is the snapshot's creation-then-id order.
pub fn BoardState::latest_running_review_attempt(
  self : BoardState,
  task_id : String,
) -> String? {
  let mut chosen = ""
  let mut chosen_at = -1.0
  for attempt in self.attempts {
    guard attempt is Object(fields) else { continue }
    if task_field(attempt, "task_id") != task_id {
      continue
    }
    if task_field(attempt, "kind") != "review" ||
      task_field(attempt, "status") != "running" {
      continue
    }
    let id = task_field(attempt, "id")
    if id == "" {
      continue
    }
    let created_at = match fields.get("created_at_ms") {
      Some(Number(value, ..)) => value
      _ => 0.0
    }
    if chosen == "" || created_at >= chosen_at {
      chosen = id
      chosen_at = created_at
    }
  }
  if chosen == "" {
    None
  } else {
    Some(chosen)
  }
}

///|
/// The delivery roles this ticket actually runs. RD is mandatory; missing or
/// malformed plans fall back to the full historical plan.
pub fn task_required_roles(task : Json) -> Array[String] {
  let fields = match task {
    Object(fields) => fields
    _ => return ["rd", "set", "te"]
  }
  match fields.get("required_roles") {
    Some(Array(values)) => {
      let roles : Array[String] = []
      for value in values {
        match value {
          String(role) if !roles.contains(role) => roles.push(role)
          _ => ()
        }
      }
      if roles.contains("rd") { roles } else { ["rd", "set", "te"] }
    }
    _ => ["rd", "set", "te"]
  }
}
