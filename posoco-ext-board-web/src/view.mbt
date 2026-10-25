///|
/// One card action button. Card actions stop click propagation: activating
/// Edit or a suggested move must not also trigger the card's
/// select-to-inspect handler.
fn card_action(
  msg : Msg,
  emit : @rabbita.Emit[Msg],
  class~ : String,
  title~ : String,
  disabled~ : Bool,
  label~ : String,
) -> @html.Html {
  @html.button(
    type_="button",
    class~,
    title~,
    disabled~,
    attrs=@html.Attrs::build().on_click(event => {
      card_action_click(event, msg, emit)
    }),
    label,
  )
}

///|
fn card_action_click(
  event : @dom.MouseEvent,
  msg : Msg,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  event.stop_propagation()
  emit(msg)
}

///|
fn labeled_field(
  id : String,
  label_text : String,
  control : @html.Html,
) -> @html.Html {
  @html.div(class="field", [@html.label(for_=id, label_text), control])
}

///|
/// A write is possible only while the replica is authoritative and no command
/// is in flight. Drafts are reported separately so the composer never claims
/// it is unavailable because it is open itself.
fn write_blocked_hint(model : Model) -> String? {
  if model.pending is Some(_) {
    Some("Wait for the current change to finish.")
  } else {
    match model.connection {
      Online =>
        if model.replica.has_snapshot() {
          None
        } else {
          Some("Waiting for the board.")
        }
      Connecting => Some("Connecting to the board.")
      Reconnecting =>
        Some("Reconnecting. The board is read-only until it returns.")
      Offline =>
        if model.can_connect {
          Some("Offline. Use Retry above to reconnect.")
        } else {
          Some("Offline. Open this page from the Board host to connect.")
        }
      ProtocolError(_) =>
        if model.can_connect {
          Some("Connection stopped. Use Retry above after checking the host.")
        } else {
          Some("Connection stopped. Reload after checking the host version.")
        }
    }
  }
}

///|
fn create_unavailable_hint(model : Model) -> String? {
  write_blocked_hint(model)
}

///|
fn can_create(model : Model) -> Bool {
  create_unavailable_hint(model) is None
}

///|
/// Why a stage move or ticket action is unavailable right now. Rendered
/// under the control, so the reason is never tooltip-only.
fn action_blocked_hint(model : Model, task_id : String) -> String? {
  match write_blocked_hint(model) {
    Some(text) => Some(text)
    None =>
      if draft_open(model) {
        Some("Finish or discard the open draft first.")
      } else if ticket_task_running(model, task_id) {
        Some(
          "This ticket is already running. Open its Activity dialog to inspect progress.",
        )
      } else {
        None
      }
  }
}

///|
fn live_chip(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let (tone, label) = match model.connection {
    Online =>
      if model.replica.has_snapshot() {
        ("is-online", "Live")
      } else {
        ("is-warn", "Waiting")
      }
    Connecting => ("is-warn", "Connecting")
    Reconnecting => ("is-warn", "Reconnecting")
    Offline => ("is-bad", "Offline")
    ProtocolError(_) => ("is-bad", "Protocol error")
  }
  @html.button(
    type_="button",
    class="btn btn-ghost btn-sm live-btn \{tone}",
    title=status_text(model),
    attrs=@html.Attrs::build()
      .aria_label("Connection: \{label}; open Cetas runtime details")
      .on_click(_ => {
        ui_show("live-dialog")
        emit(LiveOpened)
      }),
    [
      @html.span(class="live-dot", ""),
      @html.span(class="btn-label", label),
      if model.pending is Some(_) {
        @html.span(class="live-sub", "saving")
      } else {
        @html.nothing
      },
    ],
  )
}

///|
fn archive_count(model : Model) -> Int32 {
  model.replica
  .tasks()
  .filter(task => {
    task.stage is @client.Done ||
    task.stage is @client.Suspended ||
    task.stage is @client.Cancelled
  })
  .length()
}

///|
fn topbar(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let archived = archive_count(model)
  @html.header(class="topbar", [
    @html.div(class="brand", [@html.span(class="brand-mark", "Posoco Board")]),
    @html.div(class="topbar-actions", [
      live_chip(model, emit),
      if archived == 0 {
        @html.nothing
      } else {
        @html.button(
          type_="button",
          class="btn btn-sm",
          title="Open the archive: Done, Paused and Cancelled tasks",
          attrs=@html.Attrs::build().on_click(_ => {
            ui_show("archive-dialog")
            emit(ArchiveOpened)
          }),
          [
            @html.span(class="btn-icon", "▤"),
            @html.span(class="btn-label", "Archive"),
            @html.span(class="count-badge", archived.to_string()),
          ],
        )
      },
      @html.button(
        type_="button",
        class="btn btn-sm btn-inbox\{if ticket_inbox_count(model) > 0 { " is-alert" } else { "" }}",
        title="Open the ticket inbox",
        disabled=!model.ticket_available,
        attrs=@html.Attrs::build().on_click(_ => {
          ui_show("inbox-dialog")
          emit(TicketDrawerOpened)
        }),
        [
          @html.span(class="btn-icon", "✉"),
          @html.span(class="btn-label", "Inbox"),
          @html.span(
            class="count-badge",
            if ticket_inbox_count(model) == 0 {
              ""
            } else {
              ticket_inbox_count(model).to_string()
            },
          ),
        ],
      ),
      // Run Ready is the board's action when there is something to run;
      // with an empty Ready lane it recedes behind the create action.
      @html.button(
        type_="button",
        class=if ready_ticket_count(model) > 0 {
          "btn btn-primary"
        } else {
          "btn btn-ghost"
        },
        title="Run every Ready ticket as background workers",
        disabled=!model.can_connect ||
          !model.ticket_available ||
          model.ticket_sending ||
          ready_ticket_count(model) == 0,
        on_click=emit(TicketRunReady),
        [
          @html.span(class="btn-icon", "▶"),
          @html.span(class="btn-label", "Run Ready"),
        ],
      ),
      @html.button(
        type_="button",
        class="btn btn-primary",
        title=match create_unavailable_hint(model) {
          Some(text) => text
          None => "New task"
        },
        disabled=!can_create(model),
        attrs=@html.Attrs::build().on_click(_ => {
          ui_show("create-dialog")
          emit(CreateOpened)
        }),
        [
          @html.span(class="btn-label", "New task"),
          @html.span(class="kbd", "N"),
        ],
      ),
    ]),
  ])
}

///|
fn banner(text : String) -> @html.Html {
  @html.div(
    class="banner",
    attrs=@html.Attrs::build().role("status").aria_live("polite"),
    [@html.span(class="banner-dot", ""), @html.span(text)],
  )
}

///|
fn banner_retry(text : String, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @html.div(
    class="banner",
    attrs=@html.Attrs::build().role("status").aria_live("polite"),
    [
      @html.span(class="banner-dot", ""),
      @html.span(text),
      @html.button(
        type_="button",
        class="btn btn-sm banner-action",
        on_click=emit(ManualReconnect),
        "Retry",
      ),
    ],
  )
}

///|
fn connection_banner(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  match model.connection {
    Online if model.replica.has_snapshot() => @html.nothing
    Online => banner("Waiting for the board.")
    Connecting => banner("Connecting to the board.")
    Reconnecting =>
      if model.replica.has_snapshot() {
        banner("Reconnecting. Showing the last known board.")
      } else {
        banner("Reconnecting.")
      }
    Offline =>
      if model.can_connect {
        banner_retry("Offline. The connection stopped.", emit)
      } else {
        banner("Offline. Open this page from the Board host to connect.")
      }
    ProtocolError(_) =>
      if model.can_connect {
        banner_retry("Connection stopped. Retry after checking the host.", emit)
      } else {
        banner("Connection stopped. Reload after checking the host version.")
      }
  }
}

///|
fn stage_filter_options(filter : TaskFilter) -> Array[@html.Html] {
  [
    @html.option(value="", selected=filter.stage is None, "All stages"),
    ..lanes().map(stage => {
      @html.option(
        value=stage.to_wire(),
        selected=filter.stage == Some(stage),
        ui_stage_label(stage),
      )
    }),
  ]
}

///|
fn priority_filter_options(filter : TaskFilter) -> Array[@html.Html] {
  [
    @html.option(value="", selected=filter.priority is None, "All priorities"),
    ..priorities().map(priority => {
      @html.option(
        value=priority.to_wire(),
        selected=filter.priority == Some(priority),
        "\{priority_short(priority)} \{priority_label(priority)}",
      )
    }),
  ]
}

///|
fn toolbar(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let filter = model.task_filter
  // No snapshot, no count: a dash would read as data.
  let count = if model.replica.has_snapshot() {
    @html.span(class="board-count", task_count_summary(model.replica, filter))
  } else {
    @html.nothing
  }
  @html.div(class="toolbar", [
    @html.div(class="filters", [
      @html.input(
        input_type=Search,
        id="board-search",
        class="filter-search",
        placeholder="Search tasks",
        value=filter.query,
        attrs=@html.Attrs::build().aria_label(
          "Search tasks by title, ID, or description",
        ),
        on_input=value => emit(FilterQueryChanged(value)),
      ),
      @html.select(
        class="filter-select",
        attrs=@html.Attrs::build().aria_label("Filter by stage"),
        on_change=value => emit(FilterStageChanged(value)),
        stage_filter_options(filter),
      ),
      @html.select(
        class="filter-select",
        attrs=@html.Attrs::build().aria_label("Filter by priority"),
        on_change=value => emit(FilterPriorityChanged(value)),
        priority_filter_options(filter),
      ),
      if task_filter_active(filter) {
        @html.button(
          type_="button",
          class="btn btn-ghost btn-sm",
          on_click=emit(FiltersCleared),
          "Clear",
        )
      } else {
        @html.nothing
      },
    ]),
    count,
  ])
}

///|
/// The create and edit dialog body. It always renders a form so the dialog
/// has content the moment it opens; the title tracks the editor mode.
fn editor_form(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  match model.editor {
    None => @html.nothing
    Some(editor) => {
      let locked = !mutations_allowed(model)
      let id = "board-editor"
      @html.div(class="dialog-form", [
        @html.div(class="dialog-grid", [
          labeled_field(
            "\{id}-title",
            "Title",
            @html.input(
              input_type=Text,
              id="\{id}-title",
              name="title",
              class="dialog-title-input",
              value=editor.title,
              attrs=@html.Attrs::build()
                .disabled(locked)
                .aria_label("Task title")
                .data_set("autofocus", "true"),
              on_input=value => emit(TitleChanged(value)),
            ),
          ),
          labeled_field(
            "\{id}-description",
            "Description",
            @html.textarea(
              id="\{id}-description",
              name="description",
              rows=3,
              value=editor.description,
              placeholder="Optional context",
              disabled=locked,
              on_input=value => emit(DescriptionChanged(value)),
              @html.fragment([]),
            ),
          ),
          @html.div(class="dialog-pair", [
            labeled_field(
              "\{id}-priority",
              "Priority",
              @html.select(
                id="\{id}-priority",
                name="priority",
                disabled=locked,
                on_change=value => emit(PriorityChanged(value)),
                priorities().map(priority => {
                  @html.option(
                    value=priority.to_wire(),
                    selected=priority == editor.priority,
                    "\{priority_short(priority)} \{priority_label(priority)}",
                  )
                }),
              ),
            ),
            @html.div(class="dialog-stage", [
              @html.span(class="dialog-stage-label", "Lands in"),
              @html.span(class="dialog-stage-value", "Backlog"),
            ]),
          ]),
          labeled_field(
            "\{id}-dod",
            "Definition of done",
            @html.textarea(
              id="\{id}-dod",
              name="definition_of_done",
              rows=4,
              value=editor.definition_of_done,
              placeholder="One entry per line",
              disabled=locked,
              on_input=value => emit(DefinitionOfDoneChanged(value)),
              @html.fragment([]),
            ),
          ),
        ]),
      ])
    }
  }
}

///|
/// Create and edit share one native dialog: the title, the primary label and
/// the submit intent all follow the editor mode.
fn editor_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let (heading, hint, submit_label) = match model.editor {
    Some(editor) =>
      match editor.mode {
        CreateMode => ("New task", "", "Create task")
        EditMode(task_id~) => ("Edit \{task_id}", "", "Save changes")
      }
    None => ("New task", "", "Create task")
  }
  let blocked = write_blocked_hint(model)
  let title_empty = match model.editor {
    Some(editor) => editor.title.trim().is_empty()
    None => true
  }
  @html.dialog(
    id="create-dialog",
    class="dialog form-dialog",
    on_close=_ => emit(EditorCancelled),
    attrs=@html.Attrs::build().aria_label(heading),
    [
      @html.div(class="dialog-shell", [
        @html.header(class="dialog-head", [
          @html.div(class="dialog-titles", [
            @html.h2(class="dialog-title", heading),
            @html.p(
              class="dialog-subtitle",
              "One task per row of work. Shape it, scope it, then move it through the flow.",
            ),
          ]),
          close_button("create-dialog"),
        ]),
        inline_notice(model),
        @html.div(
          class="dialog-body",
          on_keydown=event => {
            if event.key() == "Enter" && event.meta_key() {
              emit(SubmitRequested)
            } else if event.key() == "Enter" && event.ctrl_key() {
              emit(SubmitRequested)
            } else {
              @rabbita.none
            }
          },
          [editor_form(model, emit)],
        ),
        match blocked {
          Some(text) => @html.p(class="dialog-hint", text)
          None => @html.nothing
        },
        match hint {
          "" => @html.nothing
          text => @html.p(class="dialog-hint", text)
        },
        @html.footer(class="dialog-foot", [
          @html.button(
            type_="button",
            class="btn",
            attrs=@html.Attrs::build().on_click(_ => {
              ui_close("create-dialog")
              @rabbita.none
            }),
            "Cancel",
          ),
          @html.button(
            type_="button",
            class="btn btn-primary",
            disabled=blocked is Some(_) || title_empty,
            attrs=@html.Attrs::build().on_click(_ => {
              ui_close("create-dialog")
              emit(SubmitRequested)
            }),
            submit_label,
          ),
        ]),
      ]),
    ],
  )
}

///|
fn close_button(dialog_id : String) -> @html.Html {
  @html.button(
    type_="button",
    class="icon-btn dialog-close",
    title="Close",
    attrs=@html.Attrs::build()
      .aria_label("Close")
      .on_click(_ => {
        ui_close(dialog_id)
        @rabbita.none
      }),
    "✕",
  )
}

///|
fn inline_notice(model : Model) -> @html.Html {
  match model.notice {
    None => @html.nothing
    Some(value) =>
      @html.div(
        class="inline-notice \{notice_class(value.severity)}",
        attrs=@html.Attrs::build().role("status").aria_live("polite"),
        [@html.span(class="notice-dot", ""), @html.span(value.text)],
      )
  }
}

///|
fn confirm_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let (title, body, action) = match model.confirm {
    Some(intent) => (intent.title(), intent.body(), intent.action())
    None => ("", "", "")
  }
  @html.dialog(
    id="confirm-dialog",
    class="dialog confirm-dialog",
    on_close=_ => emit(ConfirmDismissed),
    attrs=@html.Attrs::build().aria_label(title),
    [
      @html.div(class="dialog-shell confirm-shell", [
        @html.h2(class="confirm-title", title),
        @html.p(class="confirm-body", body),
        @html.footer(class="dialog-foot", [
          @html.button(
            type_="button",
            class="btn",
            attrs=@html.Attrs::build().on_click(_ => {
              ui_close("confirm-dialog")
              @rabbita.none
            }),
            "Cancel",
          ),
          @html.button(
            type_="button",
            class="btn btn-primary",
            attrs=@html.Attrs::build()
              .data_set("autofocus", "true")
              .on_click(_ => {
                ui_close("confirm-dialog")
                emit(ConfirmAccepted)
              }),
            action,
          ),
        ]),
      ]),
    ],
  )
}

///|
/// Pipeline stepper: every step is a move target, offered only when the v1
/// flow allows it. It makes the whole journey legible at a glance.
fn stage_stepper(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let current = stage_step(task.stage)
  let locked = !mutations_allowed(model) || draft_open(model)
  @html.nav(
    class="stepper",
    attrs=@html.Attrs::build().aria_label("Pipeline stage"),
    flow_lanes().map(stage => {
      let step = stage_step(stage).unwrap_or(0)
      let here = current == Some(step)
      let reachable = step_reachable(task.stage, stage) && !locked
      let classes = if here {
        "step is-current"
      } else if step < current.unwrap_or(0) {
        "step is-done"
      } else {
        "step"
      }
      if reachable {
        let attrs = if here {
          @html.Attrs::build().aria_current("step")
        } else {
          @html.Attrs::build()
        }
        @html.button(
          type_="button",
          class="\{classes} is-link",
          title="Move to \{ui_stage_label(stage)}",
          attrs=attrs.on_click(event => {
            card_action_click(event, MoveRequested(task.id, stage), emit)
          }),
          [
            @html.span(class="step-index", step.to_string()),
            @html.span(class="step-label", ui_stage_label(stage)),
          ],
        )
      } else {
        @html.div(class=classes, [
          @html.span(class="step-index", step.to_string()),
          @html.span(class="step-label", ui_stage_label(stage)),
        ])
      }
    }),
  )
}

///|
/// Cancelled is terminal: the task keeps its place in the archive and the
/// card menu, but it has no next stage to offer. Done and Suspended keep
/// their reopen and resume actions.
fn has_primary_intent(stage : @client.ClientBoardStage) -> Bool {
  !(stage is @client.Cancelled)
}

///|
/// Primary intent for one card, mirroring the stage FSM. Done is confirmed
/// instead of fired: it is the only step that leaves the flow.
fn primary_intent(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
  disabled~ : Bool,
  class~ : String,
) -> @html.Html {
  guard has_primary_intent(task.stage) else { return @html.nothing }
  // A failed/interrupted run stays in its lane. Its primary action is run
  // recovery, never the stage move that would turn the card into Paused.
  if ticket_task_failed(model, task.id) {
    let run = ticket_run_for(model, task.id).unwrap()
    if ticket_run_resumable(run) {
      return card_action(
        TicketResume(task.id),
        emit,
        class~,
        title="Resume run: continue this run's durable session",
        disabled=disabled || ticket_resume_blocked(model, task.id),
        label="Resume run",
      )
    }
    return card_action(
      TicketRetry(task.id),
      emit,
      class~,
      title="Start a fresh run for this failed ticket",
      disabled=disabled || ticket_retry_blocked(model, task.id),
      label="Retry work",
    )
  }
  let shaping = model.ticket_available && task.stage == @client.Created
  let running = model.ticket_available && task.stage == @client.Ready
  if shaping {
    card_action(
      TicketShape(task.id),
      emit,
      class~,
      title="Shape this ticket with an agent",
      disabled~,
      label=primary_action_label(task.stage),
    )
  } else if running {
    card_action(
      TicketRun(task.id),
      emit,
      class~,
      title="Run this ticket in the background",
      disabled~,
      label=primary_action_label(task.stage),
    )
  } else if primary_move(task.stage) is @client.Done {
    // Done leaves the flow, so it opens the consequence dialog before any
    // command exists; the command is rebuilt from live state at confirm.
    @html.button(
      type_="button",
      class~,
      title="Close this task and move it to Done",
      disabled~,
      attrs=@html.Attrs::build().on_click(event => {
        event.stop_propagation()
        ui_show("confirm-dialog")
        emit(DoneRequested(task.id))
      }),
      primary_action_label(task.stage),
    )
  } else {
    card_action(
      MoveRequested(task.id, primary_move(task.stage)),
      emit,
      class~,
      title="Move to " + ui_stage_label(primary_move(task.stage)),
      disabled~,
      label=primary_action_label(task.stage),
    )
  }
}

///|
/// The card menu's move targets: everything the FSM allows except the primary
/// intent, which is already a button, and Done, which is confirmed through its
/// own dialog. A cancelled card has no moves at all.
fn card_alternatives(
  stage : @client.ClientBoardStage,
) -> Array[@client.ClientBoardStage] {
  move_suggestions(stage).filter(to => {
    to != primary_move(stage) && to != @client.Done
  })
}

///|
fn task_card(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  // Mutation controls are a convenience only: suggested targets mirror the
  // Board stage FSM and the durable server stays authoritative.
  let locked = !mutations_allowed(model) ||
    draft_open(model) ||
    ticket_task_running(model, task.id)
  let selected = model.selected_task == Some(task.id)
  let alternatives = card_alternatives(task.stage)
  let attempt = attempt_short(model.replica, task.id)
  let attempts = attempt_count(model.replica, task.id)
  let failed_run = if ticket_task_failed(model, task.id) {
    ticket_run_for(model, task.id)
  } else {
    None
  }
  let card_class = if selected {
    "card p-\{priority_tone(task.priority)} is-selected"
  } else {
    "card p-\{priority_tone(task.priority)}"
  }
  let card_class = if failed_run is Some(_) {
    card_class + " is-error"
  } else {
    card_class
  }
  @html.article(class=card_class, [
    @html.span(class="sr-only", "\{priority_label(task.priority)} priority"),
    @html.div(class="card-top", [
      @html.span(class="card-prio", priority_short(task.priority)),
      @html.button(
        type_="button",
        class="card-title",
        title="Open task",
        attrs=@html.Attrs::build()
          .aria_controls("task-detail")
          .aria_pressed(if selected { "true" } else { "false" })
          .on_click(_ => {
            ui_show("detail-dialog")
            emit(TaskSelected(task.id))
          }),
        task.title,
      ),
    ]),
    if task.description == "" {
      @html.nothing
    } else {
      @html.p(class="card-desc", task.description)
    },
    // The card names the model only when the ticket pins one: inherit is the
    // default and belongs to the detail picker, not to every card.
    @html.div(class="card-meta", [
      if task.model is Some(_) {
        model_chip(ticket_model_catalog(model), task.model)
      } else {
        @html.nothing
      },
      if task.dependencies.length() == 0 {
        @html.nothing
      } else {
        @html.span(
          class="chip",
          dependency_count_label(task.dependencies.length()),
        )
      },
      if attempts == 0 {
        @html.nothing
      } else {
        @html.span(class="chip is-attempt", attempt)
      },
    ]),
    match failed_run {
      Some(run) =>
        @html.p(
          class="card-error",
          attrs=@html.Attrs::build().role("status"),
          match run.error {
            Some(error) => error
            None => "This run failed. Resume or retry it."
          },
        )
      None => @html.nothing
    },
    @html.footer(class="card-foot", [
      primary_intent(model, task, emit, disabled=locked, class="card-next"),
      @html.details(class="card-menu", [
        @html.summary(
          class="icon-btn",
          attrs=@html.Attrs::build().aria_label(
            "More actions for \{task.title}",
          ),
          "⋯",
        ),
        @html.div(
          class="menu",
          [
            @html.button(
              type_="button",
              class="menu-item",
              title="Open this ticket's activity",
              attrs=@html.Attrs::build().on_click(event => {
                event.stop_propagation()
                ui_show("ticket-activity-dialog")
                emit(TicketActivityOpened(task.id))
              }),
              "Activity",
            ),
            if model.ticket_available && task.stage == @client.Refining {
              card_action(
                TicketShape(task.id),
                emit,
                class="menu-item",
                title="Clarify and refine this ticket with an agent",
                disabled=locked,
                label="Shape ticket",
              )
            } else {
              @html.nothing
            },
            @html.button(
              type_="button",
              class="menu-item",
              title="Edit this task",
              disabled=locked,
              attrs=@html.Attrs::build().on_click(event => {
                event.stop_propagation()
                ui_show("create-dialog")
                emit(EditOpened(task.id))
              }),
              "Edit task",
            ),
            ..alternatives.map(to => {
              card_action(
                MoveRequested(task.id, to),
                emit,
                class="menu-item",
                title="Move to \{ui_stage_label(to)}",
                disabled=locked,
                label="Move to \{ui_stage_label(to)}",
              )
            }),
          ],
        ),
      ]),
    ]),
  ])
}

///|
fn lane(
  model : Model,
  stage : @client.ClientBoardStage,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let replica = model.replica
  let tasks = visible_lane_tasks(replica, stage, model.task_filter)
  let add = if stage is Created {
    @html.button(
      type_="button",
      class="btn btn-sm btn-primary lane-add",
      title=match create_unavailable_hint(model) {
        Some(text) => text
        None => "New task"
      },
      disabled=!can_create(model),
      attrs=@html.Attrs::build().on_click(_ => {
        ui_show("create-dialog")
        emit(CreateOpened)
      }),
      [@html.span(class="btn-icon", "+"), @html.span("New")],
    )
  } else {
    @html.nothing
  }
  @html.section(
    class="lane",
    attrs=@html.Attrs::build().aria_labelledby("lane-\{stage.to_wire()}"),
    [
      @html.header(class="lane-head", [
        @html.span(
          class="lane-step",
          stage_step(stage).unwrap_or(0).to_string(),
        ),
        @html.h2(id="lane-\{stage.to_wire()}", class="lane-title", [
          @html.span(ui_stage_label(stage)),
          @html.span(
            class="lane-count",
            lane_count_summary(replica, stage, model.task_filter),
          ),
        ]),
        add,
      ]),
      @html.div(class="lane-body", [
        if tasks.is_empty() {
          @html.p(class="lane-empty", "No tasks")
        } else {
          @html.nothing
        },
        @html.div(
          class="cards",
          tasks.map(task => task_card(model, task, emit)),
        ),
      ]),
    ],
  )
}

///|
fn skeleton_card() -> @html.Html {
  @html.div(class="skeleton-card", [
    @html.div(class="skeleton skeleton-line w-60", ""),
    @html.div(class="skeleton skeleton-line w-40", ""),
  ])
}

///|
fn loading_board() -> @html.Html {
  @html.div(class="board-area", [
    @html.p(class="sr-only", "Loading board"),
    @html.div(class="board-scroll", [
      @html.div(
        class="board",
        flow_lanes().map(stage => {
          @html.section(class="lane", [
            @html.header(class="lane-head", [
              @html.span(
                class="lane-step",
                stage_step(stage).unwrap_or(0).to_string(),
              ),
              @html.h2(class="lane-title", [
                @html.span(ui_stage_label(stage)),
                @html.span(class="lane-count", "—"),
              ]),
            ]),
            @html.div(class="lane-body", [skeleton_card(), skeleton_card()]),
          ])
        }),
      ),
    ]),
  ])
}

///|
fn empty_state(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let hint = create_unavailable_hint(model)
  @html.div(class="board-area", [
    @html.div(class="empty-state", [
      @html.div(class="empty-flow", [
        @html.span(class="empty-step", "1 Backlog"),
        @html.span(class="empty-arrow", "→"),
        @html.span(class="empty-step", "2 Shaping"),
        @html.span(class="empty-arrow", "→"),
        @html.span(class="empty-step", "3 Ready"),
        @html.span(class="empty-arrow", "→"),
        @html.span(class="empty-step", "4 Work"),
        @html.span(class="empty-arrow", "→"),
        @html.span(class="empty-step", "5 Review"),
        @html.span(class="empty-arrow", "→"),
        @html.span(class="empty-step is-end", "Done"),
      ]),
      @html.h2("No tasks yet"),
      @html.p(
        "Create the first task. It lands in Backlog, gets shaped, then moves right until it is done.",
      ),
      @html.button(
        type_="button",
        class="btn btn-primary",
        disabled=!can_create(model),
        attrs=@html.Attrs::build().on_click(_ => {
          ui_show("create-dialog")
          emit(CreateOpened)
        }),
        "New task",
      ),
      match hint {
        None =>
          @html.p(class="empty-hint", [
            @html.kbd(class="kbd", "N"),
            @html.span(" opens the composer"),
          ])
        Some(text) => @html.p(class="empty-hint", text)
      },
    ]),
  ])
}

///|
fn filtered_empty(_model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @html.div(class="board-area", [
    @html.div(class="empty-state", [
      @html.h2("No tasks match"),
      @html.p("Clear the filters to see the full board."),
      @html.button(
        type_="button",
        class="btn btn-primary",
        on_click=emit(FiltersCleared),
        "Clear filters",
      ),
    ]),
  ])
}

///|
fn board(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let replica = model.replica
  if !replica.has_snapshot() {
    return loading_board()
  }
  if replica.tasks().is_empty() {
    return empty_state(model, emit)
  }
  if filters_hide_all(replica, model.task_filter) {
    return filtered_empty(model, emit)
  }
  @html.div(class="board-area", [
    @html.div(class="board-scroll", [
      @html.div(
        class="board",
        flow_lanes().map(stage => lane(model, stage, emit)),
      ),
    ]),
  ])
}

///|
/// Archive is a second-level directory: Done, Paused and Cancelled get the
/// same card language as the flow, with room to breathe, instead of a status
/// strip.
fn archive_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let done = visible_lane_tasks(model.replica, Done, model.task_filter)
  let paused = visible_lane_tasks(model.replica, Suspended, model.task_filter)
  let cancelled = visible_lane_tasks(
    model.replica,
    Cancelled,
    model.task_filter,
  )
  @html.dialog(
    id="archive-dialog",
    class="dialog directory-dialog",
    on_close=_ => emit(ArchiveClosed),
    attrs=@html.Attrs::build().aria_label("Archive"),
    [
      @html.div(class="dialog-shell", [
        @html.header(class="dialog-head", [
          @html.div(class="dialog-titles", [
            @html.h2(class="dialog-title", "Archive"),
            @html.p(
              class="dialog-subtitle",
              "\{done.length()} done · \{paused.length()} paused · \{cancelled.length()} cancelled. Finished work leaves the flow.",
            ),
          ]),
          close_button("archive-dialog"),
        ]),
        @html.div(class="directory-body", [
          archive_section("Done", "Closed and accepted.", done, model, emit),
          archive_section(
            "Paused", "Parked without losing history.", paused, model, emit,
          ),
          archive_section(
            "Cancelled",
            stage_hint(Cancelled),
            cancelled,
            model,
            emit,
          ),
        ]),
      ]),
    ],
  )
}

///|
fn archive_section(
  title : String,
  hint : String,
  tasks : Array[@client.ClientBoardTask],
  model : Model,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @html.section(class="directory-section", [
    @html.header(class="directory-head", [
      @html.h2(class="directory-title", [
        @html.span(title),
        @html.span(class="lane-count", tasks.length().to_string()),
      ]),
      @html.span(class="directory-hint", hint),
    ]),
    if tasks.is_empty() {
      @html.p(class="lane-empty", "Nothing here.")
    } else {
      @html.div(class="cards", tasks.map(task => task_card(model, task, emit)))
    },
  ])
}

///|
fn notice_toast(notice : Notice?, emit : @rabbita.Emit[Msg]) -> @html.Html {
  match notice {
    None => @html.nothing
    Some(value) =>
      @html.div(
        class="toast \{notice_class(value.severity)}",
        attrs=@html.Attrs::build().role("status").aria_live("polite"),
        [
          @html.span(class="toast-dot", ""),
          @html.span(class="toast-text", value.text),
          @html.button(
            type_="button",
            class="toast-close",
            title="Dismiss notification",
            attrs=@html.Attrs::build().aria_label("Dismiss notification"),
            on_click=emit(NoticeDismissed),
            "✕",
          ),
        ],
      )
  }
}

///|
fn live_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let details = match model.tickets.live {
    Some(live) =>
      @html.div(class="live-details", [
        @html.div(class="live-row", [
          @html.span(class="live-key", "Manager"),
          @html.span(class="live-value mono", live.manager),
        ]),
        @html.div(class="live-row", [
          @html.span(class="live-key", "Provider"),
          @html.span(
            class="live-value mono",
            if live.provider == "" {
              "unknown"
            } else {
              live.provider
            },
          ),
        ]),
        @html.div(class="live-row", [
          @html.span(class="live-key", "Active model"),
          @html.span(class="live-value mono", live.active_model),
        ]),
        match live.active_effort {
          Some(effort) =>
            @html.div(class="live-row", [
              @html.span(class="live-key", "Effort"),
              @html.span(class="live-value mono", effort),
            ])
          None => @html.nothing
        },
        match live.context_window {
          Some(tokens) =>
            @html.div(class="live-row", [
              @html.span(class="live-key", "Context"),
              @html.span(class="live-value", "\{tokens / 1000L}k tokens"),
            ])
          None => @html.nothing
        },
        @html.div(class="live-row", [
          @html.span(class="live-key", "Available models"),
          @html.span(class="live-value", live.model_count.to_string()),
        ]),
        @html.div(class="live-row", [
          @html.span(class="live-key", "Quota"),
          @html.span(
            class="live-value",
            if live.quota_lines.is_empty() {
              "No quota readings yet"
            } else {
              live.quota_lines.join(" · ")
            },
          ),
        ]),
      ])
    None =>
      @html.p(
        class="empty-line",
        "Runtime details are not available yet. Ticket state exposes them after the first snapshot.",
      )
  }
  @html.dialog(
    id="live-dialog",
    class="dialog live-dialog",
    on_close=_ => emit(LiveClosed),
    attrs=@html.Attrs::build().aria_label("Cetas runtime"),
    [
      @html.div(class="dialog-shell", [
        @html.header(class="dialog-head", [
          @html.div(class="dialog-titles", [
            @html.h2(class="dialog-title", "Live"),
            @html.p(
              class="dialog-subtitle",
              "Connection, active model and provider manager.",
            ),
          ]),
          close_button("live-dialog"),
        ]),
        @html.div(class="dialog-body", [details]),
      ]),
    ],
  )
}

///|
fn view(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @html.main_(class="app", [
    topbar(model, emit),
    toolbar(model, emit),
    connection_banner(model, emit),
    @html.div(class="workspace", [board(model, emit)]),
    editor_dialog(model, emit),
    detail_dialog(model, emit),
    inbox_dialog(model, emit),
    ticket_activity_dialog(model, emit),
    archive_dialog(model, emit),
    live_dialog(model, emit),
    confirm_dialog(model, emit),
    notice_toast(model.notice, emit),
  ])
}
