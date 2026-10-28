///|
/// Host-side run state for every ticket: role-scoped child runs keyed by task.
/// The store is the single owner of that state, so a dismissed run has no
/// projection left anywhere else.
pub struct WorkRunStore {
  map : Map[String, Array[WorkRun]]
}

///|
pub fn WorkRunStore::WorkRunStore() -> WorkRunStore {
  { map: Map([]) }
}

///|
/// The run array of one task, creating it when absent, so callers that append
/// runs never special-case the first role.
pub fn WorkRunStore::runs_for(
  self : WorkRunStore,
  task_id : String,
) -> Array[WorkRun] {
  match self.map.get(task_id) {
    Some(runs) => runs
    None => {
      let runs : Array[WorkRun] = []
      self.map[task_id] = runs
      runs
    }
  }
}

///|
/// The run the task-level UI reads first: a live role wins, otherwise the most
/// recently added role.
pub fn WorkRunStore::run_for(
  self : WorkRunStore,
  task_id : String,
) -> WorkRun? {
  let runs = match self.map.get(task_id) {
    Some(runs) => runs
    None => return None
  }
  for run in runs {
    if run.status == "running" {
      return Some(run)
    }
  }
  runs.get(runs.length() - 1)
}

///|
/// The last run of one role on one task, or `None`.
pub fn WorkRunStore::run_role(
  self : WorkRunStore,
  task_id : String,
  role : String,
) -> WorkRun? {
  match self.map.get(task_id) {
    Some(runs) => {
      let mut found : WorkRun? = None
      for run in runs {
        if run.role == role {
          found = Some(run)
        }
      }
      found
    }
    None => None
  }
}

///|
pub fn WorkRunStore::all(self : WorkRunStore) -> Array[WorkRun] {
  let out : Array[WorkRun] = []
  for runs in self.map.values() {
    for run in runs {
      out.push(run)
    }
  }
  out
}

///|
/// Record one started run in phase `work` (or `shape`) with status `running`.
pub fn WorkRunStore::add(
  self : WorkRunStore,
  task_id : String,
  session_id : String,
  phase : String,
  role : String,
) -> WorkRun {
  let run : WorkRun = {
    task_id,
    session_id,
    phase,
    role,
    status: "running",
    error: None,
    result: None,
    report: None,
    steps: 0,
    current_tool: None,
    preview: "",
    reasoning: "",
    activities: [],
  }
  self.runs_for(task_id).push(run)
  run
}

///|
/// Record one run's status and error. A dismissed run has no projection left;
/// the Board fact still moved, so there is nothing to update.
pub fn WorkRunStore::set_status(
  self : WorkRunStore,
  task_id : String,
  role : String,
  status : String,
  error : String?,
) -> Unit {
  match self.run_role(task_id, role) {
    Some(run) => {
      run.status = status
      run.error = error
    }
    None => ()
  }
}

///|
/// Record a finished run without moving the Board. A worker failure —
/// including a paused network stream — must stay in its current lane with a
/// visible error so the durable session can be resumed; moving it to Paused
/// would discard that recovery path. The Board stage moves only when a command
/// explicitly asks for it.
pub fn WorkRunStore::park(
  self : WorkRunStore,
  task_id : String,
  role : String,
  status : String,
  error : String,
) -> Unit {
  self.set_status(task_id, role, status, Some(error))
}

///|
/// Whether every listed role has a completed run on the task.
pub fn WorkRunStore::roles_completed(
  self : WorkRunStore,
  task_id : String,
  roles : Array[String],
) -> Bool {
  for role in roles {
    match self.run_role(task_id, role) {
      Some(run) => if run.status != "completed" { return false }
      None => return false
    }
  }
  true
}

///|
pub fn WorkRunStore::count_running(self : WorkRunStore) -> Int32 {
  let mut running = 0
  for run in self.all() {
    if run.status == "running" {
      running = running + 1
    }
  }
  running
}

///|
pub fn WorkRunStore::dismiss(self : WorkRunStore, task_id : String) -> Unit {
  self.map.remove(task_id)
}
