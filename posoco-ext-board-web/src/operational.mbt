///|
fn mutation_availability_note(model : Model) -> String? {
  if model.pending is Some(_) {
    return Some(
      "Another change cannot be submitted until this command settles.",
    )
  }
  match model.connection {
    Connecting => Some("Mutations are unavailable while connecting.")
    Reconnecting if model.replica.has_snapshot() =>
      Some(
        "The retained snapshot is shown for reference, not as live state. Mutations are unavailable during reconnect.",
      )
    Reconnecting =>
      Some(
        "Mutations are unavailable until a fresh authoritative snapshot arrives.",
      )
    Offline =>
      Some(
        "Mutations are unavailable offline. Open Board from its host to connect.",
      )
    ProtocolError(_) =>
      Some(
        "Mutations are unavailable. Automatic reconnect stopped; check host compatibility before reloading this page. Any retained snapshot is for reference only.",
      )
    Online if !model.replica.has_snapshot() =>
      Some("Mutations are unavailable until authoritative Board state arrives.")
    Online => None
  }
}

///|
fn manual_lifecycle_note() -> String {
  "Agent execution: Not connected. Task stages, manual attempt status and review decisions are independent. Task Done does not verify execution success; Review Approved does not finish an attempt."
}

///|
fn selection_filter_note(model : Model) -> String? {
  match inspector_task(model) {
    Some(task) if !task_matches_filter(task, model.task_filter) =>
      Some(
        "The inspected task is hidden by the current filters. Its details and drafts remain available.",
      )
    _ => None
  }
}

///|
fn inspector_sections() -> Array[(String, String)] {
  [
    ("inspector-task-details", "Task details"),
    ("inspector-dependencies", "Dependencies"),
    ("inspector-attempts", "Attempts and reviews"),
  ]
}
