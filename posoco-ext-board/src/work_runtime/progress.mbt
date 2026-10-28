///|
/// One progress update of one ticket, as the host keeps and projects it.
pub(all) struct WorkProgress {
  task_id : String
  kind : String
  message : String
  at_ms : Int64
}

///|
/// Per-ticket bound on the progress log: a long run reports many lines and
/// only the recent ones are useful beside it.
pub let work_progress_max_per_ticket : Int32 = 50

///|
/// Bounded per-ticket progress log. Progress is Information only, so
/// dismissing it never changes the Board or a run.
pub struct WorkProgressLog {
  map : Map[String, Array[WorkProgress]]
}

///|
pub fn WorkProgressLog::WorkProgressLog() -> WorkProgressLog {
  { map: Map([]), }
}

///|
/// Append one worker progress update for a ticket, dropping the oldest once
/// the per-ticket bound is reached. Blank messages are dropped: a worker that
/// reports nothing has said nothing.
pub fn WorkProgressLog::record(
  self : WorkProgressLog,
  task_id : String,
  kind : String,
  message : String,
) -> Unit {
  let text = message.trim().to_owned()
  if text.is_empty() {
    return
  }
  let updates = match self.map.get(task_id) {
    Some(updates) => updates
    None => {
      let updates : Array[WorkProgress] = []
      self.map[task_id] = updates
      updates
    }
  }
  updates.push({ task_id, kind, message: text, at_ms: @async.now(), })
  while updates.length() > work_progress_max_per_ticket {
    ignore(updates.remove(0))
  }
}

///|
/// Clear updates, all of them or one ticket's.
pub fn WorkProgressLog::dismiss(
  self : WorkProgressLog,
  task_id : String?,
) -> Unit {
  match task_id {
    Some(task_id) => ignore(self.map.remove(task_id))
    None => self.map.clear()
  }
}

///|
/// Every retained update across all tickets, in log order.
pub fn WorkProgressLog::all(self : WorkProgressLog) -> Array[WorkProgress] {
  let out : Array[WorkProgress] = []
  for updates in self.map.values() {
    for update in updates {
      out.push(update)
    }
  }
  out
}

///|
/// How many tickets currently carry at least one attention or blocked update.
pub fn WorkProgressLog::attention_tasks(self : WorkProgressLog) -> Int32 {
  let mut attention = 0
  for updates in self.map.values() {
    if updates.any(update => {
        update.kind == "attention" || update.kind == "blocked"
      }) {
      attention = attention + 1
    }
  }
  attention
}

///|
/// The host projection of one progress update.
pub fn WorkProgress::to_json(self : WorkProgress) -> Json {
  Json::object({
    "task_id": Json::string(self.task_id),
    "kind": Json::string(self.kind),
    "message": Json::string(self.message),
    "at_ms": Json::number(self.at_ms.to_double()),
  })
}
