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
    ("inspector-dependencies", "Dependencies"),
    ("inspector-dod", "Definition of done"),
    ("inspector-attempts", "Runs"),
    ("inspector-task-details", "Details"),
  ]
}
