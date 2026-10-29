///|
/// One activity line of one run: what the child did, bounded per run.
pub(all) struct WorkActivity {
  at_ms : Int64
  kind : String
  text : String
}

///|
/// Per-run bound on the activity log: a long run reports many lines and only
/// the recent ones are useful beside the run.
let work_run_activity_max : Int32 = 20

///|
/// One background work run for one ticket role. The host keeps this
/// projection; the Board stage stays the authority for the ticket itself.
pub(all) struct WorkRun {
  task_id : String
  session_id : String
  phase : String
  role : String
  mut status : String
  mut error : String?
  mut result : String?
  mut report : Json?
  mut steps : Int32
  mut current_tool : String?
  mut preview : String
  mut reasoning : String
  activities : Array[WorkActivity]
}

///|
/// Append one activity line, dropping the oldest once the per-run bound is
/// reached. Activity is host projection only: it never touches the Board.
pub fn WorkRun::activity(self : WorkRun, kind : String, text : String) -> Unit {
  self.activities.push({ at_ms: @async.now(), kind, text, })
  while self.activities.length() > work_run_activity_max {
    ignore(self.activities.remove(0))
  }
}

///|
/// Keep only the last `max` characters of the combined text, so a streamed
/// preview stays bounded without splitting a surrogate pair it has already
/// accepted.
pub fn append_tail(current : String, addition : String, max : Int32) -> String {
  let combined = current + addition
  let chars : Array[Char] = []
  for char in combined {
    chars.push(char)
  }
  let start = if chars.length() > max { chars.length() - max } else { 0 }
  let mut out = ""
  for index in start..<chars.length() {
    out = out + chars[index].to_string()
  }
  out
}

///|
/// Collapse whitespace and cut one line to `max` characters, for previews of
/// tool arguments and prompts inside an activity line.
pub fn one_line_preview(text : String, max : Int32) -> String {
  let mut out = ""
  let mut pending_space = false
  for char in text {
    if char == ' ' || char == '\n' || char == '\t' || char == '\r' {
      pending_space = out.length() > 0
    } else {
      if pending_space {
        out = out + " "
        pending_space = false
      }
      out = out + char.to_string()
      if out.length() >= max {
        break
      }
    }
  }
  out
}

///|
/// The host projection of one run. Keys are the wire format the Board
/// dashboard reads; they do not change with internal refactors.
pub fn WorkRun::to_json(self : WorkRun) -> Json {
  Json::object({
    "task_id": Json::string(self.task_id),
    "session_id": Json::string(self.session_id),
    "phase": Json::string(self.phase),
    "role": Json::string(self.role),
    "status": Json::string(self.status),
    "error": match self.error {
      Some(text) => Json::string(text)
      None => Json::null()
    },
    "result": match self.result {
      Some(text) => Json::string(text)
      None => Json::null()
    },
    "steps": Json::number(self.steps.to_double()),
    "current_tool": match self.current_tool {
      Some(text) => Json::string(text)
      None => Json::null()
    },
    "preview": Json::string(self.preview),
    "reasoning": Json::string(self.reasoning),
    "activities": Json::array(
      self.activities.map(activity => activity.to_json()),
    ),
  })
}

///|
pub fn WorkActivity::to_json(self : WorkActivity) -> Json {
  Json::object({
    "at_ms": Json::number(self.at_ms.to_double()),
    "kind": Json::string(self.kind),
    "text": Json::string(self.text),
  })
}

///|
fn run_string(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(String(value)) => value
    _ => ""
  }
}

///|
fn run_optional_string(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
pub fn WorkRun::from_json(value : Json) -> WorkRun? {
  let fields = match value {
    Object(fields) => fields
    _ => return None
  }
  let task_id = run_string(fields, "task_id")
  let role = run_string(fields, "role")
  if task_id == "" || role == "" {
    return None
  }
  let activities : Array[WorkActivity] = []
  match fields.get("activities") {
    Some(Array(items)) =>
      for item in items {
        match item {
          Object(fields) => {
            let at_ms = match fields.get("at_ms") {
              Some(Number(value, ..)) => value.to_int64()
              _ => 0L
            }
            activities.push({
              at_ms,
              kind: run_string(fields, "kind"),
              text: run_string(fields, "text"),
            })
          }
          _ => ()
        }
      }
    _ => ()
  }
  Some({
    task_id,
    session_id: run_string(fields, "session_id"),
    phase: run_string(fields, "phase"),
    role,
    status: run_string(fields, "status"),
    error: run_optional_string(fields, "error"),
    result: run_optional_string(fields, "result"),
    report: match fields.get("report") {
      Some(Json::Null) => None
      Some(value) => Some(value)
      None => None
    },
    steps: match fields.get("steps") {
      Some(Number(value, ..)) => value.to_int()
      _ => 0
    },
    current_tool: run_optional_string(fields, "current_tool"),
    preview: run_string(fields, "preview"),
    reasoning: run_string(fields, "reasoning"),
    activities,
  })
}
