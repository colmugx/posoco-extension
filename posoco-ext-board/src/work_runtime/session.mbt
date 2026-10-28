///|
/// Durable child session id of one role's run on one ticket. The id is stable
/// across host restarts, so a resume continues the same recorded session.
pub fn work_session_id(task_id : String, role : String) -> String {
  "ticket-" + task_id + "-" + role
}

///|
/// Durable child session id of one ticket's shaping run.
pub fn shape_session_id(task_id : String) -> String {
  "shape-" + task_id
}
