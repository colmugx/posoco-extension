///|
/// Adapter from the model's severity spelling to the component tone vocabulary.
fn notice_tone(severity : NoticeSeverity) -> @ui.NoticeTone {
  match severity {
    Success => @ui.NoticeTone::Success
    Warning => @ui.NoticeTone::Warning
    Error => @ui.NoticeTone::Error
  }
}

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
    @html.div(class="brand", [
      @html.span(class="brand-mark", "Cetas Board"),
      if model.tickets.project == "" {
        @html.nothing
      } else {
        @html.span(class="brand-flow", model.tickets.project)
      },
    ]),
    @html.div(class="topbar-actions", [
      live_chip(model, emit),
      @html.button(
        type_="button",
        class="btn btn-sm btn-ghost",
        title="Customize team names",
        attrs=@html.Attrs::build().on_click(_ => {
          ui_show("team-dialog")
          emit(TeamOpened)
        }),
        [@html.span(class="btn-icon", "◎"), @html.span(class="btn-label", "Team")],
      ),
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
      @html.button(
        type_="button",
        class="btn btn-primary",
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
    ]),
  ])
}

///|
fn connection_banner(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  match model.connection {
    Online if model.replica.has_snapshot() => @html.nothing
    Online => @ui.banner("Waiting for the board.")
    Connecting => @ui.banner("Connecting to the board.")
    Reconnecting =>
      if model.replica.has_snapshot() {
        @ui.banner("Reconnecting. Showing the last known board.")
      } else {
        @ui.banner("Reconnecting.")
      }
    Offline =>
      if model.can_connect {
        @ui.banner_retry("Offline. The connection stopped.", emit(ManualReconnect))
      } else {
        @ui.banner("Offline. Open this page from the Board host to connect.")
      }
    ProtocolError(_) =>
      if model.can_connect {
        @ui.banner_retry(
          "Connection stopped. Retry after checking the host.",
          emit(ManualReconnect),
        )
      } else {
        @ui.banner("Connection stopped. Reload after checking the host version.")
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
      @ui.search_input(
        id="board-search",
        placeholder="Search tasks",
        value=filter.query,
        aria_label="Search tasks by title, ID, or description",
        on_input=value => emit(FilterQueryChanged(value)),
        style=["width:auto", "flex:1 1 240px", "max-width:360px"],
      ),
      @ui.select_field(
        id="filter-stage",
        name="filter_stage",
        disabled=false,
        aria_label="Filter by stage",
        on_change=value => emit(FilterStageChanged(value)),
        stage_filter_options(filter),
      ),
      @ui.select_field(
        id="filter-priority",
        name="filter_priority",
        disabled=false,
        aria_label="Filter by priority",
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
      let creating = editor.mode is CreateMode
      if creating {
        return @html.div(class="dialog-form", [
          @ui.text_area(
            id="\{id}-idea",
            name="idea",
            label="What do you want to build?",
            value=editor.description,
            rows=6,
            placeholder="Describe the idea in your own words. Rough notes are enough.",
            disabled=locked,
            on_input=value => emit(DescriptionChanged(value)),
          ),
          @html.p(
            class="dialog-hint",
            "A Product Owner turns this into a user story, sets the priority, and writes the definition of done.",
          ),
        ])
      }
      let story_fields = if creating {
        @html.p(
          class="dialog-hint",
          "A Product Owner turns this into a user story, sets the P0-P3 priority, and writes the definition of done.",
        )
      } else {
        @html.fragment([
          @ui.text_area(
            id="\{id}-user-story",
            name="user_story",
            label="User story",
            value=editor.user_story,
            rows=3,
            placeholder="As a ..., I want ..., so that ...",
            disabled=locked,
            on_input=value => emit(UserStoryChanged(value)),
          ),
          @ui.text_area(
            id="\{id}-suggestions",
            name="implementation_suggestions",
            label="Implementation suggestions",
            value=editor.implementation_suggestions,
            rows=3,
            placeholder="Starting points, not a mandate",
            disabled=locked,
            on_input=value => emit(ImplementationSuggestionsChanged(value)),
          ),
        ])
      }
      let priority_and_dod = if creating {
        @html.nothing
      } else {
        @html.fragment([
          @html.div(class="dialog-pair", [
            @ui.select_field(
              id="\{id}-priority",
              name="priority",
              label="Priority",
              value=editor.priority.to_wire(),
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
            @html.div(class="dialog-stage", [
              @html.span(class="dialog-stage-label", "Stage"),
              @html.span(class="dialog-stage-value", "Ready needs all fields"),
            ]),
          ]),
          @ui.text_area(
            id="\{id}-dod",
            name="definition_of_done",
            label="Definition of done",
            value=editor.definition_of_done,
            rows=4,
            placeholder="One entry per line",
            disabled=locked,
            on_input=value => emit(DefinitionOfDoneChanged(value)),
          ),
        ])
      }
      @html.div(class="dialog-form", [
        @html.div(class="dialog-grid", [
          @ui.text_input(
            id="\{id}-title",
            name="title",
            label="Title",
            value=editor.title,
            placeholder="",
            disabled=locked,
            autofocus=true,
            aria_label="Task title",
            on_input=value => emit(TitleChanged(value)),
          ),
          @ui.text_area(
            id="\{id}-description",
            name="description",
            label="Description",
            value=editor.description,
            rows=if creating { 4 } else { 3 },
            placeholder=if creating {
              "What should change? Rough notes are enough."
            } else {
              "Detailed scope and constraints"
            },
            disabled=locked,
            on_input=value => emit(DescriptionChanged(value)),
          ),
          story_fields,
          priority_and_dod,
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
        CreateMode =>
          (
            "New backlog item", "A Product Owner turns it into a user story and sets the initial priority.",
            "Add to Backlog",
          )
        EditMode(task_id~) => ("Edit \{task_id}", "", "Save changes")
      }
    None => ("New backlog item", "", "Add to Backlog")
  }
  let blocked = write_blocked_hint(model)
  let idea_empty = match model.editor {
    Some(editor) =>
      if editor.mode is CreateMode {
        editor.description.trim().is_empty()
      } else {
        editor.title.trim().is_empty()
      }
    None => true
  }
  @ui.dialog(
    "create-dialog",
    heading,
    _ => emit(EditorCancelled),
    ["width:min(calc(100% - 2rem),54rem)","max-height:calc(100vh - 3rem)"],
    [
      @html.div(class="dialog-shell", [
        @html.header(class="dialog-head", [
          @html.div(class="dialog-titles", [
            @html.h2(class="dialog-title", heading),
            @html.p(
              class="dialog-subtitle",
              "A backlog item becomes a story during Shaping.",
            ),
          ]),
        ]),
        inline_notice(model, emit),
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
            disabled=blocked is Some(_) || idea_empty,
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
fn inline_notice(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  match model.notice {
    None => @html.nothing
    Some(value) =>
      @ui.notice(
        notice_tone(value.severity),
        value.text,
        on_dismiss=emit(NoticeDismissed),
        class="inline-notice",
      )
  }
}

///|
fn confirm_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let (title, body, action) = match model.confirm {
    Some(intent) => (intent.title(), intent.body(), intent.action())
    None => ("", "", "")
  }
  @ui.dialog(
    "confirm-dialog",
    title,
    _ => emit(ConfirmDismissed),
    ["width:min(calc(100% - 2rem),26rem)"],
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
/// Pipeline stepper: every step is a move target, offered only when the
/// current flow allows it. It makes the whole journey legible at a glance.
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
/// instead of fired: it is the only step that leaves the flow. `shown` is
/// the stage the card renders at — the authoritative stage, or the target of
/// an in-flight move.
fn primary_intent(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
  shown~ : @client.ClientBoardStage,
  disabled~ : Bool,
  class~ : String,
) -> @html.Html {
  guard has_primary_intent(shown) else { return @html.nothing }
  let ready_blocked = primary_move(shown) is Ready &&
    ready_blocked_hint(task) is Some(_)
  let disabled = disabled || ready_blocked
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
  let shaping = model.ticket_available && shown == @client.Created
  let running = model.ticket_available && shown == @client.Ready
  if shaping {
    card_action(
      TicketShape(task.id),
      emit,
      class~,
      title="Shape this ticket with an agent",
      disabled~,
      label=primary_action_label(shown),
    )
  } else if running {
    card_action(
      TicketRun(task.id),
      emit,
      class~,
      title="Run this ticket in the background",
      disabled~,
      label=primary_action_label(shown),
    )
  } else if primary_move(shown) is @client.Done {
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
      primary_action_label(shown),
    )
  } else {
    card_action(
      MoveRequested(task.id, primary_move(shown)),
      emit,
      class~,
      title="Move to " + ui_stage_label(primary_move(shown)),
      disabled~,
      label=primary_action_label(shown),
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
  // An in-flight move renders at its target stage; every stage-facing label
  // follows it while the authoritative record stays untouched.
  let shown = staged_stage(task, model.optimistic)
  let selected = model.selected_task == Some(task.id)
  let alternatives = card_alternatives(shown)
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
  let created = shown is @client.Created
  @html.article(class=card_class, [
    @html.span(class="sr-only", "\{priority_label(task.priority)} priority"),
    @html.div(class="card-top", [
      @html.span(class="card-prio", priority_short(task.priority)),
      @html.button(
        type_="button",
        class=if created { "card-title card-idea" } else { "card-title" },
        title="Open task",
        attrs=@html.Attrs::build()
          .aria_controls("task-detail")
          .aria_pressed(if selected { "true" } else { "false" })
          .on_click(_ => {
            ui_show("detail-dialog")
            emit(TaskSelected(task.id))
          }),
        if created {
          if task.description == "" { task.title } else { task.description }
        } else {
          task.title
        },
      ),
    ]),
    if created || task.description == "" {
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
        @ui.chip(
          dependency_count_label(task.dependencies.length()),
          @ui.ChipTone::Quiet,
        )
      },
      if attempts == 0 {
        @html.nothing
      } else {
        @ui.chip(attempt, @ui.ChipTone::Quiet)
      },
      if pending_for_task(model.pending, task.id) {
        @ui.chip("saving", @ui.ChipTone::Running)
      } else {
        @html.nothing
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
      primary_intent(
        model,
        task,
        emit,
        shown~,
        disabled=locked,
        class="card-next",
      ),
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
            if model.ticket_available && shown == @client.Refining {
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
                // Destructive moves read as such instead of matching every
                // other row; the durable server still owns the decision.
                class=if to == @client.Cancelled || to == @client.Suspended {
                  "menu-item is-danger"
                } else {
                  "menu-item"
                },
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

///|
/// One pass over the replica per render: the visible, deterministically
/// ordered tasks feed every lane, the counts and the archive, and each task
/// is placed by its staged (optimistic) stage.
fn lane(
  model : Model,
  stage : @client.ClientBoardStage,
  visible : Array[@client.ClientBoardTask],
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let replica = model.replica
  let tasks = visible.filter(task => {
    staged_stage(task, model.optimistic) == stage
  })
  let count = lane_count_label(
    replica,
    visible,
    stage,
    model.optimistic,
    model.task_filter,
  )
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
          @html.span(class="lane-count", count),
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
    @ui.skeleton_line("skeleton-line w-60"),
    @ui.skeleton_line("skeleton-line w-40"),
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
    @ui.empty_shell([
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
    @ui.empty_shell([
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
  // One visible computation per render feeds every lane; the stale veil sits
  // above the board while the reconnect replays the missed frames.
  let visible = visible_tasks(replica, model.task_filter)
  @html.div(class="board-area", [
    if model.stale {
      @html.div(class="stale-veil", attrs=@html.Attrs::build().role("status"), [
        @html.p("The board is out of date. Reconnecting for fresh state."),
        @html.button(
          type_="button",
          class="btn btn-sm",
          on_click=emit(ManualReconnect),
          "Refresh",
        ),
      ])
    } else {
      @html.nothing
    },
    @html.div(class="board-scroll", [
      @html.div(
        class="board",
        flow_lanes().map(stage => lane(model, stage, visible, emit)),
      ),
    ]),
  ])
}

///|
/// Archive is a second-level directory: Done, Paused and Cancelled get the
/// same card language as the flow, with room to breathe, instead of a status
/// strip.
fn archive_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let visible = visible_tasks(model.replica, model.task_filter)
  let archived = stage => {
    visible.filter(task => staged_stage(task, model.optimistic) == stage)
  }
  let done = archived(Done)
  let paused = archived(Suspended)
  let cancelled = archived(Cancelled)
  @ui.dialog(
    "archive-dialog",
    "Archive",
    _ => emit(ArchiveClosed),
    ["width:min(calc(100% - 2rem),74rem)","height:min(82vh,900px)"],
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
/// The live region is persistent: it is always in the DOM and only its
/// content changes, so assistive tech hears the first notice too. An action
/// (today: undoing a move) rides inside the toast.
fn notice_toast(notice : Notice?, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @html.div(
    class="toast-region",
    attrs=@html.Attrs::build().role("status").aria_live("polite"),
    [
      match notice {
        None => @html.nothing
        Some(value) =>
          match value.action {
            Some(action) =>
              @ui.notice_with_action(
                notice_tone(value.severity),
                value.text,
                action_label=action.label,
                action_aria="\{action.label}: move the task back to \{ui_stage_label(action.move_to)}",
                action_cmd=emit(NoticeActionInvoked),
                on_dismiss=emit(NoticeDismissed),
                class="toast",
              )
            None =>
              @ui.notice(
                notice_tone(value.severity),
                value.text,
                on_dismiss=emit(NoticeDismissed),
                class="toast",
              )
          }
      },
    ],
  )
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
  @ui.dialog(
    "live-dialog",
    "Cetas runtime",
    _ => emit(LiveClosed),
    ["width:min(calc(100% - 2rem),35rem)"],
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
        ]),
        @html.div(class="dialog-body", [details]),
      ]),
    ],
  )
}

///|
fn team_name_field(
  id : String,
  label : String,
  value : String,
  role : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @ui.text_input(
    id~,
    name=id,
    label~,
    value~,
    placeholder="",
    disabled=false,
    autofocus=false,
    aria_label=label,
    on_input=text => emit(TeamNameChanged(role, text)),
  )
}

///|
fn team_role_name(draft : TeamNames, role : String) -> String {
  match role {
    "po" | "refiner" => draft.po
    "sm" => draft.sm
    "rd" => draft.rd
    "set" => draft.set
    _ => draft.te
  }
}

///|
fn team_mcp_for(draft : TeamNames, role : String) -> TeamMcp {
  match draft.mcp.get(role) {
    Some(value) => value
    None => TeamMcp::defaults()
  }
}

///|
fn team_tab(
  draft : TeamNames,
  role : String,
  active : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  @html.button(
    type_="button",
    class=if role == active { "team-tab is-active" } else { "team-tab" },
    attrs=@html.Attrs::build()
      .role("tab")
      .aria_selected(if role == active { "true" } else { "false" })
      .on_click(_ => emit(TeamTabChanged(role))),
    team_role_name(draft, role),
  )
}

///|
fn team_skills_for(draft : TeamNames, role : String) -> TeamSkills {
  match draft.skills.get(role) {
    Some(value) => value
    None => TeamSkills::defaults()
  }
}

///|
fn team_skills_panel(
  model : Model,
  draft : TeamNames,
  role : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let config = team_skills_for(draft, role)
  let skills = model.tickets.skills
  @html.section(class="team-section", [
    @html.h3(class="section-title", "Skills"),
    @html.label(class="team-check", [
      @html.input(
        input_type=Checkbox,
        id="team-skills-enabled",
        name="team_skills_enabled",
        checked=config.enabled,
        on_change=_ => emit(TeamSkillsEnabledChanged(role, !config.enabled)),
      ),
      @html.span("Allow this member to use host-discovered skills"),
    ]),
    if !config.enabled {
      @html.p(
        class="empty-line",
        "Skills are off for this member. The agent gets no skill catalog or activation tools.",
      )
    } else if skills.is_empty() {
      @html.p(
        class="empty-line",
        "The host discovered no skills. Add SKILL.md files, then reopen this dialog.",
      )
    } else {
      @html.div(class="team-mcp", [
        @html.div(class="team-mode", [
          @html.label(class="team-check", [
            @html.input(
              input_type=Radio,
              name="team_skills_mode",
              value="all",
              checked=config.all,
              on_change=_ => emit(TeamSkillsAllChanged(role, true)),
            ),
            @html.span("All host skills"),
          ]),
          @html.label(class="team-check", [
            @html.input(
              input_type=Radio,
              name="team_skills_mode",
              value="selected",
              checked=!config.all,
              on_change=_ => emit(TeamSkillsAllChanged(role, false)),
            ),
            @html.span("Selected skills"),
          ]),
        ]),
        @html.div(
          class="team-servers",
          skills.map(skill => {
            let checked = config.all || config.skills.contains(skill.name)
            @html.label(
              class=if config.all {
                "team-server is-muted"
              } else {
                "team-server"
              },
              [
                @html.input(
                  input_type=Checkbox,
                  name="team_skill",
                  value=skill.name,
                  checked~,
                  attrs=@html.Attrs::build().disabled(config.all),
                  on_change=_ => emit(TeamSkillToggled(role, skill.name)),
                ),
                @html.span(class="team-server-name", skill.name),
                @html.span(
                  class="team-skill-desc",
                  if skill.description == "" {
                    "no description"
                  } else {
                    skill.description
                  },
                ),
              ],
            )
          }),
        ),
      ])
    },
  ])
}

///|
fn team_mcp_panel(
  model : Model,
  draft : TeamNames,
  role : String,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let config = team_mcp_for(draft, role)
  let servers = model.tickets.mcp_servers
  @html.div(class="team-page", [
    team_name_field("team-name", "Name", team_role_name(draft, role), role, emit),
    @html.section(class="team-section", [
      @html.h3(class="section-title", "MCP"),
      @html.label(class="team-check", [
        @html.input(
          input_type=Checkbox,
          id="team-mcp-enabled",
          name="team_mcp_enabled",
          checked=config.enabled,
          on_change=_ => emit(TeamMcpEnabledChanged(role, !config.enabled)),
        ),
        @html.span("Allow this member to use host-configured MCP servers"),
      ]),
      if !config.enabled {
        @html.p(
          class="empty-line",
          "MCP is off for this member. The tools stay hidden from its agent.",
        )
      } else if servers.is_empty() {
        @html.p(
          class="empty-line",
          "The host has no configured MCP servers. Add them in mcp.json, then reopen this dialog.",
        )
      } else {
        @html.div(class="team-mcp", [
          @html.div(class="team-mode", [
            @html.label(class="team-check", [
              @html.input(
                input_type=Radio,
                name="team_mcp_mode",
                value="all",
                checked=config.all,
                on_change=_ => emit(TeamMcpAllChanged(role, true)),
              ),
              @html.span("All host servers"),
            ]),
            @html.label(class="team-check", [
              @html.input(
                input_type=Radio,
                name="team_mcp_mode",
                value="selected",
                checked=!config.all,
                on_change=_ => emit(TeamMcpAllChanged(role, false)),
              ),
              @html.span("Selected servers"),
            ]),
          ]),
          @html.div(
            class="team-servers",
            servers.map(server => {
              let checked = config.all || config.servers.contains(server.name)
              @html.label(
                class=if config.all {
                  "team-server is-muted"
                } else {
                  "team-server"
                },
                [
                  @html.input(
                    input_type=Checkbox,
                    name="team_mcp_server",
                    value=server.name,
                    checked~,
                    attrs=@html.Attrs::build().disabled(config.all),
                    on_change=_ =>
                      emit(TeamMcpServerToggled(role, server.name)),
                  ),
                  @html.span(class="team-server-name", server.name),
                  @html.span(
                    class=if server.connected {
                      "chip is-running"
                    } else {
                      "chip is-quiet"
                    },
                    if server.connected {
                      "\{server.tools.length()} tools"
                    } else {
                      "not connected"
                    },
                  ),
                ],
              )
            }),
          ),
          @html.label(class="team-check", [
            @html.input(
              input_type=Checkbox,
              name="team_mcp_restrict_tools",
              checked=config.tools.length() > 0,
              on_change=_ =>
                emit(TeamMcpToolsRestricted(role, config.tools.is_empty())),
            ),
            @html.span("Only selected tools"),
          ]),
          if config.tools.is_empty() {
            @html.p(
              class="empty-line",
              "Every tool from the allowed servers is available.",
            )
          } else {
            @html.div(class="team-tools", {
              let groups : Array[@html.Html] = []
              for server in servers {
                let selected = config.all ||
                  config.servers.contains(server.name)
                if selected && !server.tools.is_empty() {
                  groups.push(
                    @html.div(class="team-tool-group", [
                      @html.span(class="team-tool-server", server.name),
                      @html.div(
                        class="team-tool-list",
                        server.tools.map(tool =>
                          @html.label(class="team-check team-tool", [
                            @html.input(
                              input_type=Checkbox,
                              name="team_mcp_tool",
                              value=tool,
                              checked=config.tools.contains(tool),
                              on_change=_ =>
                                emit(TeamMcpToolToggled(role, tool)),
                            ),
                            @html.span(tool),
                          ])
                        ),
                      ),
                    ]),
                  )
                }
              }
              groups
            })
          },
        ])
      },
    ]),
    team_skills_panel(model, draft, role, emit),
  ])
}

///|
fn team_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let draft = model.team_draft
  let draft_profile = model.team_profile_draft
  let roles = ["po", "sm", "rd", "set", "te"]
  @ui.dialog(
    "team-dialog",
    "Team settings",
    _ => emit(TeamClosed),
    ["width:min(calc(100% - 2rem),46rem)"],
    [
      @html.div(class="dialog-shell", [
        @html.header(class="dialog-head", [
          @html.div(class="dialog-titles", [
            @html.h2(class="dialog-title", "Team settings"),
            @html.p(
              class="dialog-subtitle",
              "Each member has a name and its own MCP access. MCP servers come from the host's mcp.json.",
            ),
          ]),
        ]),
        @html.div(class="dialog-body", [
          @ui.select_field(
            id="team-profile",
            name="work_profile",
            label="Work profile",
            disabled=false,
            on_change=value => emit(TeamProfileChanged(value)),
            work_profiles().map(profile => {
              @html.option(
                value=profile.id,
                selected=profile.id == draft_profile.id,
                profile.label,
              )
            }),
          ),
          @html.div(
            class="team-tabs",
            roles.map(role => {
              team_tab(draft, role, model.team_tab, emit)
            }),
          ),
          team_mcp_panel(model, draft, model.team_tab, emit),
        ]),
        @html.footer(class="dialog-foot", [
          @html.div(class="dialog-actions", [
            @html.button(
              type_="button",
              class="btn",
              attrs=@html.Attrs::build().on_click(_ => {
                ui_close("team-dialog")
                emit(TeamClosed)
              }),
              "Cancel",
            ),
            @html.button(
              type_="button",
              class="btn btn-primary",
              disabled=model.ticket_sending || !model.ticket_available,
              attrs=@html.Attrs::build().on_click(_ => {
                ui_close("team-dialog")
                emit(TeamSaved)
              }),
              "Save team",
            ),
          ]),
        ]),
      ]),
    ],
  )
}

///|
fn view(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @ui.theme_root(@html.main_(class="app", [
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
    team_dialog(model, emit),
    confirm_dialog(model, emit),
    notice_toast(model.notice, emit),
  ]))
}
