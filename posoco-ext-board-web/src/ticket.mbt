///|
/// Locate the first running attempt, or the newest matching attempt.
/// A single pass avoids allocating a filtered run array for every card render.
fn ticket_run_for(model : Model, task_id : String) -> TicketRun? {
  let mut latest : TicketRun? = None
  for run in model.tickets.runs {
    if run.task_id == task_id {
      if run.status == "running" {
        return Some(run)
      }
      latest = Some(run)
    }
  }
  latest
}

///|
/// A run that failed in place is still Recovery C state: keep the ticket in its
/// lane, paint it as an error, and offer Resume run/Retry work instead of a
/// stage move to Paused.
fn ticket_task_failed(model : Model, task_id : String) -> Bool {
  match ticket_run_for(model, task_id) {
    Some(run) => ticket_run_retryable(run.status)
    None => false
  }
}

///|
fn ticket_task_running(model : Model, task_id : String) -> Bool {
  model.tickets.runs.any(run => {
    run.task_id == task_id && run.status == "running"
  })
}

///|
fn apply_ticket_state(model : Model, state : TicketState) -> Model {
  // The catalog is runtime projection, not ticket journal state: a frame that
  // omitted it (for example a `ticket_result`) keeps the last known catalog
  // instead of disabling a picker the user is looking at.
  let model_selection = match state.model_selection {
    Some(_) => state.model_selection
    None => model.tickets.model_selection
  }
  let live = match state.live {
    Some(_) => state.live
    None => model.tickets.live
  }
  let project = if state.project == "" {
    model.tickets.project
  } else {
    state.project
  }
  let team = match state.team {
    Some(_) => state.team
    None => model.tickets.team
  }
  {
    ..model,
    tickets: { ..state, project, team, live, model_selection, },
    // Only the updates still on the wire stay "seen": a worker that tore down
    // takes its updates with it, so its identities must not linger.
    ticket_seen_updates: ticket_progress_retain_seen(
      model.ticket_seen_updates,
      state.progress,
    ),
    ticket_available: true,
    ticket_sending: false,
  }
}

///|
fn ticket_rejection_text(reason : String?) -> String {
  match reason {
    Some("ticket is already running") =>
      "This ticket is already running. Open its Activity dialog to inspect progress."
    Some("ticket must be Backlog, Shaping, or Ready before it can be shaped") =>
      "Move the ticket back to Backlog or Shaping before shaping it again."
    Some("ticket must be Ready before it can run") =>
      "Shape the ticket and move it to Ready before starting work."
    Some("board_work_unavailable") =>
      "The Board ticket runtime is unavailable. Restart Cetas with workflows enabled."
    Some("ticket_start_failed") | Some("ticket_shape_failed") =>
      "The ticket could not start. Open its Activity dialog for the failure detail."
    Some(text) if text != "" => text
    _ => "The ticket command was rejected."
  }
}

///|
fn apply_ticket_outcome(
  model : Model,
  ok : Bool,
  reason : String?,
  state : TicketState?,
) -> Model {
  let next = match state {
    Some(state) => apply_ticket_state(model, state)
    None =>
      ({ ..model, ticket_available: true, ticket_sending: false, } : Model)
  }
  if ok {
    { ..next, last_status: "Ticket updated", }
  } else {
    let already_running = reason == Some("ticket is already running")
    {
      ..next,
      notice: Some(
        notice(
          Warning,
          if already_running {
            "This ticket is already running. Open its Activity dialog to inspect progress."
          } else {
            ticket_rejection_text(reason)
          },
        ),
      ),
    }
  }
}

