///|
fn ready_ticket_count(model : Model) -> Int32 {
  model.replica.tasks().filter(task => task.stage == @client.Ready).length()
}

///|
fn team_member_label(model : Model, role : String) -> String {
  let team = match model.tickets.team {
    Some(team) => team
    None => TeamNames::defaults()
  }
  match role {
    "customer" => "Customer"
    "po" => team.po
    "sm" => team.sm
    "rd" => team.rd
    "set" => team.set
    "te" => team.te
    "development_group" | "worker" => "Development"
    _ => role
  }
}

///|
fn ticket_question_card(
  model : Model,
  question : TicketQuestion,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let title = match task_by_id(model.replica, question.task_id) {
    Some(task) => task.title
    None => question.task_id
  }
  let draft = model.ticket_drafts.get(question.id).unwrap_or("")
  let po_name = team_member_label(model, "po")
  let answer_controls = match question.kind {
    "confirm" =>
      @html.div(class="ticket-answers", [
        @html.button(
          type_="button",
          class="btn btn-sm",
          disabled=model.ticket_sending,
          on_click=emit(TicketAnswered(question.id, TicketConfirm(true))),
          "Yes",
        ),
        @html.button(
          type_="button",
          class="btn btn-sm",
          disabled=model.ticket_sending,
          on_click=emit(TicketAnswered(question.id, TicketConfirm(false))),
          "No",
        ),
      ])
    "select" => {
      let buttons : Array[@html.Html] = []
      for index in 0..<question.options.length() {
        buttons.push(
          @html.button(
            type_="button",
            class="btn btn-sm",
            disabled=model.ticket_sending,
            on_click=emit(TicketAnswered(question.id, TicketSelect(index))),
            question.options[index],
          ),
        )
      }
      @html.div([
        @html.div(class="ticket-answers", buttons),
        @html.div(class="ticket-other", [
          @html.div(class="ticket-other-label", "Other answer"),
          @html.div(class="ticket-answers", [
            @ui.text_area(
              id="ticket-other-\{question.id}",
              name="ticket_other",
              value=draft,
              rows=3,
              placeholder="None of these fit? Write your answer…",
              disabled=model.ticket_sending,
              on_input=value => emit(TicketDraftChanged(question.id, value)),
            ),
            @html.button(
              type_="button",
              class="btn btn-sm btn-primary",
              disabled=model.ticket_sending || draft.trim().is_empty(),
              on_click=emit(TicketAnswered(question.id, TicketText(draft))),
              "Send other",
            ),
            @html.button(
              type_="button",
              class="btn btn-sm",
              disabled=model.ticket_sending || draft.trim().is_empty(),
              on_click=emit(TicketAnsweredAsPo(question.id, draft)),
              "Answer as " + po_name,
            ),
          ]),
        ]),
      ])
    }
    _ =>
      @html.div(class="ticket-answers", [
        @ui.text_area(
          id="ticket-answer-\{question.id}",
          name="ticket_answer",
          value=draft,
          rows=4,
          placeholder="Write your answer or feedback…",
          disabled=model.ticket_sending,
          on_input=value => emit(TicketDraftChanged(question.id, value)),
        ),
        @html.button(
          type_="button",
          class="btn btn-sm btn-primary",
          disabled=model.ticket_sending || draft.trim().is_empty(),
          on_click=emit(TicketAnswered(question.id, TicketText(draft))),
          "Send",
        ),
        @html.button(
          type_="button",
          class="btn btn-sm",
          disabled=model.ticket_sending || draft.trim().is_empty(),
          on_click=emit(TicketAnsweredAsPo(question.id, draft)),
          "Answer as " + po_name,
        ),
      ])
  }
  @html.div(class="ticket-question", [
    @html.div(class="ticket-question-meta", [
      @html.span(class="ticket-question-task", title),
      @html.span(class="ticket-question-kind", question.kind),
      @html.span(
        class="ticket-question-route",
        "\{team_member_label(model, question.asked_by)} → \{team_member_label(model, question.audience)}",
      ),
    ]),
    @html.div(class="ticket-question-text", question.question),
    answer_controls,
    @html.div(class="ticket-answers", [
      @html.button(
        type_="button",
        class="btn btn-sm",
        disabled=model.ticket_sending,
        on_click=emit(TicketPoRequested(question.id)),
        "Ask " + po_name,
      ),
    ]),
  ])
}

///|
/// Per-ticket Activity dialog: live and finished runs belong to the ticket,
/// not to the question inbox.
fn ticket_activity_dialog(
  model : Model,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let task_id = match model.ticket_activity_task {
    Some(task_id) => task_id
    None =>
      // The element must exist before the Activity click can open it: `ui_show`
      // looks the dialog up by id, so a dialog rendered only for a selected
      // ticket would be missing on the very first click.
      return @ui.sheet_dialog(
        "ticket-activity-dialog",
        "Ticket activity",
        _ => emit(TicketActivityClosed),
        "40rem",
        [
          @html.div(class="sheet", [
            @html.p(class="section-note", "Open a ticket to see its activity."),
          ]),
        ],
      )
  }
  let task = task_by_id(model.replica, task_id)
  let title = match task {
    Some(task) => task.title
    None => task_id
  }
  let runs = model.tickets.runs.filter(run => run.task_id == task_id)
  let run_label = if runs.length() == 1 {
    "1 run"
  } else {
    "\{runs.length()} runs"
  }
  @ui.sheet_dialog(
    "ticket-activity-dialog",
    "Ticket activity",
    _ => emit(TicketActivityClosed),
    "40rem",
    [
      @html.div(class="sheet", [
        @html.header(class="sheet-head", [
          @html.div(class="sheet-heading", [
            @html.nav(
              class="crumbs",
              attrs=@html.Attrs::build().aria_label("Breadcrumb"),
              [
                @html.button(
                  type_="button",
                  class="crumb-link",
                  attrs=@html.Attrs::build().on_click(_ => {
                    ui_close("ticket-activity-dialog")
                    @rabbita.none
                  }),
                  "Board",
                ),
                @html.span(class="crumb-sep", "/"),
                @html.span(class="crumb-here", title),
                @html.span(class="crumb-sep", "/"),
                @html.span(class="crumb-here", "Activity"),
              ],
            ),
            @html.h2(class="sheet-title", "Activity"),
            @html.p(class="sheet-meta", [
              @ui.chip(
                if runs.is_empty() {
                  "No runs yet"
                } else {
                  run_label
                },
                @ui.ChipTone::Quiet,
              ),
              @ui.chip(task_id, @ui.ChipTone::Quiet),
            ]),
          ]),
        ]),
        @html.div(
          class="sheet-body ticket-activity-body",
          if runs.is_empty() {
            [
              @html.div(
                class="empty-line",
                "No agent activity yet. Shape or run this ticket to start.",
              ),
              ticket_stage_retry_action(model, task, task_id, emit),
            ]
          } else {
            runs.map(run => {
              if run.status == "running" {
                ticket_run_card(model, run)
              } else {
                ticket_result_card(model, run, emit)
              }
            })
          },
        ),
      ]),
    ],
  )
}

///|
/// One inbox update row. It is information only: no answer control, no stage
/// move and no dismiss, because the worker owns the run and the host owns the
/// list.
fn ticket_update_card(update : InboxUpdate) -> @html.Html {
  let unseen = if update.unseen { " is-unseen" } else { "" }
  @html.article(class="ticket-update kind-\{update.kind}\{unseen}", [
    @html.div(class="ticket-update-meta", [
      @html.span(class="ticket-update-task", title=update.task_id, update.title),
      @html.span(class="ticket-update-kind", update.kind_label),
      if update.unseen {
        @html.span(class="ticket-update-new", "New")
      } else {
        @html.nothing
      },
      @html.span(
        class="ticket-update-time",
        title=utc_timestamp(update.at_ms),
        update.time_label,
      ),
    ]),
    @html.p(class="ticket-update-text", update.message),
  ])
}

///|
/// The Updates block. It sits above the questions because it is the freshest
/// thing the workers said, and it states in words that no reply is expected so
/// an update never reads as an unanswered question.
fn ticket_updates_section(
  updates : Array[InboxUpdate],
  unseen_count : Int32,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @html.section(
    class="inbox-updates",
    attrs=@html.Attrs::build().aria_label("Worker updates"),
    [
      @html.header(class="inbox-section-head", [
        @html.h3(class="inbox-section-title", "Updates"),
        @html.span(
          class="inbox-section-hint",
          if unseen_count == 0 {
            "Information only — no reply needed."
          } else {
            "Information only — \{ticket_update_count_label(unseen_count)} since you last opened the inbox."
          },
        ),
        @html.button(
          type_="button",
          class="btn btn-sm inbox-dismiss",
          title="Dismiss these updates",
          attrs=@html.Attrs::build().on_click(_ => emit(TicketUpdatesDismissed)),
          "Dismiss",
        ),
      ]),
      @html.div(
        class="inbox-update-list",
        updates.map(update => ticket_update_card(update)),
      ),
    ],
  )
}

///|
/// The inbox holds two different things: questions that need a human answer,
/// and worker updates that need nothing. Live and finished run detail lives on
/// the ticket's own Activity dialog.
fn inbox_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let question_count = ticket_question_count(model)
  let update_count = model.tickets.progress.length()
  let unseen_count = ticket_unseen_update_count(model)
  let updates = inbox_updates(model, board_now_ms())
  let items : Array[@html.Html] = []
  if !updates.is_empty() {
    items.push(ticket_updates_section(updates, unseen_count, emit))
  }
  for question in model.tickets.questions {
    if is_customer_question(question) {
      items.push(ticket_question_card(model, question, emit))
    }
  }
  if question_count == 0 {
    items.push(@html.div(class="empty-line", "No open questions."))
  }
  @ui.sheet_dialog(
    "inbox-dialog",
    "Ticket inbox",
    _ => emit(TicketDrawerClosed),
    "34rem",
    [
      @html.div(class="sheet", [
        @html.header(class="sheet-head", [
          @html.div(class="sheet-heading", [
            @html.nav(
              class="crumbs",
              attrs=@html.Attrs::build().aria_label("Breadcrumb"),
              [
                @html.button(
                  type_="button",
                  class="crumb-link",
                  attrs=@html.Attrs::build().on_click(_ => {
                    ui_close("inbox-dialog")
                    @rabbita.none
                  }),
                  "Board",
                ),
                @html.span(class="crumb-sep", "/"),
                @html.span(class="crumb-here", "Inbox"),
              ],
            ),
            @html.h2(class="sheet-title", "Inbox"),
            @html.p(class="sheet-meta", [
              if question_count == 0 {
                @ui.chip("No open questions", @ui.ChipTone::Quiet)
              } else {
                @ui.chip(
                  "\{question_count} awaiting an answer",
                  @ui.ChipTone::Pinned,
                )
              },
              if update_count == 0 {
                @html.nothing
              } else {
                @ui.chip(
                  ticket_update_total_label(update_count),
                  @ui.ChipTone::Quiet,
                )
              },
              if unseen_count == 0 {
                @html.nothing
              } else {
                @ui.chip(
                  ticket_update_count_label(unseen_count),
                  @ui.ChipTone::Running,
                )
              },
            ]),
          ]),
        ]),
        @html.div(class="sheet-body inbox-body", items),
      ]),
    ],
  )
}
