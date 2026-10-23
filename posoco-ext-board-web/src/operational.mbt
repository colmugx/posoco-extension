///|
fn selection_filter_note(model : Model) -> String? {
  match inspector_task(model) {
    Some(task) if !task_matches_filter(task, model.task_filter) =>
      Some(
        "This task is hidden by the current filters. Its details and drafts remain available.",
      )
    _ => None
  }
}
