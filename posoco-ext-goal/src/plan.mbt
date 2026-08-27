///|
/// Lifecycle of one plan item.
pub(all) enum GoalPlanStatus {
  Pending
  InProgress
  Done
} derive(Eq, Debug)

///|
pub impl Show for GoalPlanStatus with fn to_string(self : GoalPlanStatus) -> String {
  match self {
    Pending => "pending"
    InProgress => "in_progress"
    Done => "done"
  }
}

///|
pub(all) struct GoalPlanItem {
  title : String
  status : GoalPlanStatus
} derive(Eq, Debug)

///|
pub(all) struct GoalPlan {
  items : Array[GoalPlanItem]
} derive(Eq, Debug)

///|
pub fn GoalPlan::empty() -> GoalPlan {
  GoalPlan::{ items: [] }
}

///|
/// Read a required string field from a JSON object.
fn string_field(
  fields : Map[String, Json],
  key : String,
) -> Result[String, String] {
  match fields.get(key) {
    Some(Json::String(value)) => Ok(value)
    Some(_) => Err("plan item field \"\{key}\" must be a string")
    None => Err("plan item is missing \"\{key}\"")
  }
}

///|
/// Map a status string onto GoalPlanStatus; None when unrecognized.
fn parse_plan_status(raw : String) -> GoalPlanStatus? {
  match raw {
    "pending" => Some(Pending)
    "in_progress" => Some(InProgress)
    "done" => Some(Done)
    _ => None
  }
}

///|
/// Parse one plan item object: {"title": String, "status": "pending"|"in_progress"|"done"}.
fn parse_plan_item(elem : Json) -> Result[GoalPlanItem, String] {
  match elem {
    Json::Object(fields) =>
      match (string_field(fields, "title"), fields.get("status")) {
        (Err(reason), _) => Err(reason)
        (Ok(_), None) => Err("plan item is missing \"status\"")
        (Ok(title), Some(Json::String(raw))) =>
          match parse_plan_status(raw) {
            Some(status) => Ok(GoalPlanItem::{ title, status })
            None => Err("unknown status \"\{raw}\" for plan item \"\{title}\"")
          }
        (Ok(_), Some(_)) => Err("plan item field \"status\" must be a string")
      }
    _ => Err("each plan item must be a JSON object")
  }
}

///|
/// Parse the goal_update_plan tool arguments: {"items": [{"title": String, "status": "pending"|"in_progress"|"done"}]}
/// Err carries a short user-facing reason (surfaced upstream as a ToolReportedError).
pub fn GoalPlan::from_tool_args(args : Json) -> Result[GoalPlan, String] {
  match args {
    Json::Object(fields) =>
      match fields.get("items") {
        Some(Json::Array(elems)) => {
          if elems.length() == 0 {
            return Err("plan must contain at least one item")
          }
          let items : Array[GoalPlanItem] = []
          for elem in elems {
            match parse_plan_item(elem) {
              Ok(item) => items.push(item)
              Err(reason) => return Err(reason)
            }
          }
          Ok(GoalPlan::{ items, })
        }
        Some(_) => Err("\"items\" must be an array")
        None => Err("arguments are missing \"items\"")
      }
    _ => Err("arguments must be a JSON object")
  }
}

///|
/// Enforce exactly one InProgress: the first InProgress wins; extras become Pending. Returns a new plan (pure).
pub fn GoalPlan::normalize(plan : GoalPlan) -> GoalPlan {
  let mut seen_in_progress = false
  let items : Array[GoalPlanItem] = []
  for item in plan.items {
    match item.status {
      InProgress if seen_in_progress =>
        items.push(GoalPlanItem::{ title: item.title, status: Pending })
      InProgress => {
        seen_in_progress = true
        items.push(item)
      }
      _ => items.push(item)
    }
  }
  GoalPlan::{ items, }
}

///|
/// Markdown checklist: Done → "- [x] <title>"; InProgress → "- [ ] <title> (in progress)";
/// Pending → "- [ ] <title>"; empty plan → "(no plan yet — decompose the goal)"
pub fn GoalPlan::render(plan : GoalPlan) -> String {
  if plan.items.length() == 0 {
    return "(no plan yet — decompose the goal)"
  }
  let lines : Array[String] = []
  for item in plan.items {
    match item.status {
      Done => lines.push("- [x] \{item.title}")
      InProgress => lines.push("- [ ] \{item.title} (in progress)")
      Pending => lines.push("- [ ] \{item.title}")
    }
  }
  lines.join("\n")
}

///|
/// One-line progress, e.g. "plan: 2/5 done" ("plan: 0/0 done" for the empty plan)
pub fn GoalPlan::progress_line(plan : GoalPlan) -> String {
  let mut done = 0
  for item in plan.items {
    if item.status == Done {
      done = done + 1
    }
  }
  "plan: \{done}/\{plan.items.length()} done"
}

///|
/// InProgress title if any, else first Pending title, else None
pub fn GoalPlan::next_step(plan : GoalPlan) -> String? {
  for item in plan.items {
    if item.status == InProgress {
      return Some(item.title)
    }
  }
  for item in plan.items {
    if item.status == Pending {
      return Some(item.title)
    }
  }
  None
}

///|
/// Stable serialization for stall detection: items joined as "title:status" with "|" (empty plan → "")
pub fn GoalPlan::fingerprint(plan : GoalPlan) -> String {
  let parts : Array[String] = []
  for item in plan.items {
    parts.push("\{item.title}:\{item.status}")
  }
  parts.join("|")
}
