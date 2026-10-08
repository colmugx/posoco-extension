///|
pub fn lanes() -> Array[@client.ClientBoardStage] {
  [Created, Refining, Ready, Running, Review, Done, Suspended]
}

///|
pub fn stage_label(stage : @client.ClientBoardStage) -> String {
  match stage {
    Created => "Created"
    Refining => "Refining"
    Ready => "Ready"
    Running => "Running"
    Review => "Review"
    Done => "Done"
    Suspended => "Suspended"
  }
}

///|
pub fn priority_label(priority : @client.ClientBoardPriority) -> String {
  match priority {
    Low => "Low"
    Normal => "Normal"
    High => "High"
    Critical => "Critical"
  }
}

///|
pub fn tasks_in_lane(
  replica : @client.BoardReplica,
  stage : @client.ClientBoardStage,
) -> Array[@client.ClientBoardTask] {
  replica.tasks().filter(task => task.stage == stage)
}

///|
pub fn attempt_count(replica : @client.BoardReplica, task_id : String) -> Int {
  replica.attempts().filter(attempt => attempt.task_id == task_id).length()
}

///|
pub fn attempt_indicator(
  replica : @client.BoardReplica,
  task_id : String,
) -> String {
  let attempts = replica
    .attempts()
    .filter(attempt => attempt.task_id == task_id)
  for attempt in attempts {
    if attempt.status is Running {
      return "Running"
    }
  }
  let mut latest : @client.ClientAttempt? = None
  for attempt in attempts {
    match latest {
      None => latest = Some(attempt)
      Some(previous) if attempt.updated_at_ms >= previous.updated_at_ms =>
        latest = Some(attempt)
      _ => ()
    }
  }
  match latest {
    None => "No attempts"
    Some(attempt) =>
      match attempt.status {
        Queued => "Queued"
        Running => "Running"
        Succeeded => "Succeeded"
        Failed => "Failed"
        Cancelled => "Cancelled"
        Interrupted => "Interrupted"
      }
  }
}

///|
pub fn empty_message(replica : @client.BoardReplica) -> String? {
  if replica.tasks().is_empty() {
    Some("No Board tasks yet")
  } else {
    None
  }
}
