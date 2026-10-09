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
/// Fixed option order for the editor priority select. Wire spelling always
/// comes from the client's centralized `to_wire`, never from this package.
pub fn priorities() -> Array[@client.ClientBoardPriority] {
  [Low, Normal, High, Critical]
}

///|
/// Move suggestions are a UX convenience mirroring the Board v1 stage FSM;
/// the durable server stays authoritative and may still reject a move. The
/// table covers every stage so the view can render a control row for any
/// card.
pub fn move_suggestions(
  stage : @client.ClientBoardStage,
) -> Array[@client.ClientBoardStage] {
  match stage {
    Created => [Refining, Suspended]
    Refining => [Ready, Suspended]
    Ready => [Running, Refining, Suspended]
    Running => [Review, Suspended]
    Review => [Done, Ready, Refining, Suspended]
    Done => [Refining]
    Suspended => [Created, Refining, Ready]
  }
}

///|
/// Split a definition-of-done draft into entries: one entry per line with
/// surrounding whitespace dropped and empty lines removed.
pub fn definition_of_done_lines(text : String) -> Array[String] {
  text
  .split("\n")
  .map(line => line.trim().to_owned())
  .filter(line => line != "")
  .collect()
}

///|
/// Join definition-of-done entries back into the multi-line editor draft.
pub fn definition_of_done_text(lines : Array[String]) -> String {
  lines.join("\n")
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
/// Loading and empty are distinct: without an authoritative snapshot the
/// board is unknown, not empty. Invalidation clears the records, so no
/// stale cards survive a resync.
pub fn empty_message(replica : @client.BoardReplica) -> String? {
  if !replica.has_snapshot() {
    Some("Waiting for Board state")
  } else if replica.tasks().is_empty() {
    Some("No Board tasks yet")
  } else {
    None
  }
}
