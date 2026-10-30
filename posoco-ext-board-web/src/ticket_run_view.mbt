///|
/// The action one finished run offers under its card. Resume run continues the
/// durable session the interrupted run already owns; Retry starts a new run and
/// clears it.
priv enum TicketRunAction {
  ResumeRun
  RetryRun
}

///|
/// The actions one finished run offers, primary first. A recoverable run with a
/// durable session prefers continuing it, so Resume run comes first and Retry
/// follows as the fresh-attempt escape hatch; a run whose session did not
/// survive only offers Retry.
fn ticket_run_actions(run : TicketRun) -> Array[TicketRunAction] {
  let actions : Array[TicketRunAction] = []
  if ticket_run_resumable(run) {
    actions.push(ResumeRun)
  }
  if ticket_run_retryable(run.status) {
    actions.push(RetryRun)
  }
  actions
}

///|
/// Resume run and Retry mean different things, so the interrupted card states
/// both consequences instead of leaving the user to guess which one keeps
/// context. The label keeps "run" so it never reads as the ticket's own
/// Suspended → Ready Resume move.
fn ticket_resume_note() -> String {
  "Resume run continues the durable session where it stopped. Retry starts a new run and clears it."
}

///|
/// The visible label of one finished-run action. Resume run stays distinct from
/// the card's own Suspended → Ready Resume stage move.
fn ticket_run_action_label(action : TicketRunAction) -> String {
  match action {
    ResumeRun => "Resume run"
    RetryRun => "Retry work"
  }
}

///|
fn ticket_run_action_button(
  model : Model,
  task_id : String,
  action : TicketRunAction,
  primary : Bool,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let button_class = if primary {
    "btn btn-sm btn-primary"
  } else {
    "btn btn-sm"
  }
  match action {
    ResumeRun =>
      @html.button(
        type_="button",
        class=button_class,
        title="Resume run: continue this run's durable session",
        disabled=ticket_resume_blocked(model, task_id),
        on_click=emit(TicketResume(task_id)),
        ticket_run_action_label(action),
      )
    RetryRun =>
      @html.button(
        type_="button",
        class=button_class,
        title="Start a fresh run for this ticket",
        disabled=ticket_retry_blocked(model, task_id),
        on_click=emit(TicketRetry(task_id)),
        ticket_run_action_label(action),
      )
  }
}

///|
/// Resume and Retry for one finished run card, or nothing when that run still
/// holds a live worker or already produced a result worth keeping. The gate only
/// disables the buttons: an interrupted run keeps offering both while the
/// socket reconnects.
fn ticket_run_action_block(
  model : Model,
  run : TicketRun,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let actions = ticket_run_actions(run)
  if actions.is_empty() {
    return @html.nothing
  }
  let buttons : Array[@html.Html] = []
  for index, action in actions {
    buttons.push(
      ticket_run_action_button(model, run.task_id, action, index == 0, emit),
    )
  }
  let resumable = actions.any(action => action is ResumeRun)
  @html.div(class="ticket-run-actions", [
    @html.div(class="ticket-answers", buttons),
    @html.p(
      class="ticket-run-actions-note",
      if resumable {
        ticket_resume_note()
      } else {
        ticket_retry_note()
      },
    ),
  ])
}

///|
/// A paused ticket that never started a run has no card to retry, so the
/// dialog still offers Retry work next to the ticket's own Resume move.
fn ticket_stage_retry_action(
  model : Model,
  task : @client.ClientBoardTask?,
  task_id : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let has_run = model.tickets.runs.any(run => run.task_id == task_id)
  match task {
    Some(task) if task.stage is @client.Suspended && !has_run =>
      ticket_retry_action(model, task_id, emit)
    _ => @html.nothing
  }
}

///|
fn ticket_activity_list(activities : Array[TicketActivity]) -> @html.Html {
  let items : Array[@html.Html] = []
  let start = if activities.length() > 20 {
    activities.length() - 20
  } else {
    0
  }
  for index in start..<activities.length() {
    let activity = activities[index]
    items.push(
      @html.div(
        class="ticket-activity-row kind-\{activity.kind}",
        @html.span(class="ticket-activity-text", activity.text),
      ),
    )
  }
  @html.div(class="ticket-activity-list", items)
}

///|
fn ticket_run_card(model : Model, run : TicketRun) -> @html.Html {
  let title = match task_by_id(model.replica, run.task_id) {
    Some(task) => task.title
    None => run.task_id
  }
  let phase = if run.phase == "shape" {
    "Shaping"
  } else {
    match run.role {
      "" => "Working"
      "te" => "Verification · " + team_member_label(model, run.role)
      role => "Working · " + team_member_label(model, role)
    }
  }
  let tool = match run.current_tool {
    Some(name) => " · " + name
    None => ""
  }
  let preview = if run.preview == "" {
    "Waiting for the first model response…"
  } else {
    run.preview
  }
  @html.div(class="ticket-question ticket-run", [
    @html.div(class="ticket-question-meta", [
      @html.span(class="ticket-question-task", title),
      @html.span(class="ticket-question-kind", phase + tool),
    ]),
    // The newest worker update sits above the live preview: it is the same
    // information the inbox shows, repeated where the run is inspected.
    match ticket_latest_update(model, run.task_id) {
      Some(update) =>
        @html.div(class="ticket-update is-compact kind-\{update.kind}", [
          @html.span(
            class="ticket-update-kind",
            ticket_progress_kind_label(update.kind),
          ),
          @html.span(class="ticket-update-text", update.message),
        ])
      None => @html.nothing
    },
    @html.div(class="ticket-run-preview", preview),
    if run.reasoning == "" {
      @html.nothing
    } else {
      @html.details(class="ticket-reasoning", [
        @html.summary("Reasoning"),
        @html.div(class="ticket-reasoning-text", run.reasoning),
      ])
    },
    ticket_activity_list(run.activities),
    @html.div(
      class="ticket-run-foot",
      "Step \{run.steps} · updates automatically while the worker runs.",
    ),
  ])
}

///|
fn ticket_result_card(
  model : Model,
  run : TicketRun,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let title = match task_by_id(model.replica, run.task_id) {
    Some(task) => task.title
    None => run.task_id
  }
  @html.div(class="ticket-question ticket-result", [
    @html.div(class="ticket-question-meta", [
      @html.span(class="ticket-question-task", title),
      @html.span(class="ticket-question-kind", run.status),
    ]),
    @html.div(
      class=if run.error is Some(_) {
        "ticket-result-text ticket-result-error"
      } else {
        "ticket-result-text"
      },
      match run.result {
        Some(text) => text
        None =>
          match run.error {
            Some(text) => text
            None => "No result recorded."
          }
      },
    ),
    if run.activities.is_empty() {
      @html.nothing
    } else {
      ticket_activity_list(run.activities)
    },
    ticket_run_action_block(model, run, emit),
    @html.div(class="ticket-answers", [
      @html.button(
        type_="button",
        class="btn btn-sm",
        disabled=model.ticket_sending,
        on_click=emit(TicketResultDismissed(run.task_id)),
        "Dismiss",
      ),
    ]),
  ])
}

