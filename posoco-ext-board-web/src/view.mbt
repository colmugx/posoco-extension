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
  if draft_open(model) {
    Some("Finish or cancel the open editor first.")
  } else {
    write_blocked_hint(model)
  }
}

///|
fn can_create(model : Model) -> Bool {
  create_unavailable_hint(model) is None
}

///|
fn inspector_open(model : Model) -> Bool {
  model.selected_task is Some(_) ||
  model.dependency_editor is Some(_) ||
  model.attempt_draft is Some(_) ||
  model.finish_draft is Some(_) ||
  model.review_draft is Some(_)
}

///|
fn live_chip(model : Model) -> @html.Html {
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
  @html.span(
    class="live \{tone}",
    title=status_text(model),
    attrs=@html.Attrs::build().aria_label("Connection: \{label}"),
    [
      @html.span(class="live-dot", ""),
      @html.span(label),
      if model.pending is Some(_) {
        @html.span(class="live-sub", "saving")
      } else {
        @html.nothing
      },
    ],
  )
}

///|
fn topbar(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let hint = create_unavailable_hint(model)
  @html.header(class="topbar", [
    @html.div(class="brand", "Board"),
    @html.div(class="topbar-actions", [
      live_chip(model),
      @html.button(
        type_="button",
        class="btn btn-sm",
        title="Open the ticket inbox",
        disabled=!model.ticket_available,
        on_click=emit(TicketDrawerToggled),
        [
          @html.span("Inbox"),
          @html.span(
            class="ticket-badge",
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
        class="btn btn-sm",
        title="Run the next Ready ticket as a background worker",
        disabled=!model.can_connect ||
          !model.ticket_available ||
          model.ticket_sending ||
          ready_ticket_count(model) == 0,
        on_click=emit(TicketRunReady),
        "Run next",
      ),
      @html.button(
        type_="button",
        class="btn btn-primary new-task",
        title=match hint {
          Some(text) => text
          None => "Create a task (N)"
        },
        disabled=!can_create(model),
        on_click=emit(CreateOpened),
        [@html.span("New task"), @html.kbd(class="kbd", "N")],
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
  let count = if model.replica.has_snapshot() {
    task_count_summary(model.replica, filter)
  } else {
    "—"
  }
  @html.div(class="toolbar", [
    @html.div(class="filters", [
      @html.input(
        input_type=Search,
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
    @html.span(class="board-count", count),
  ])
}

///|
fn composer_panel(
  model : Model,
  editor : Editor,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let blocked = write_blocked_hint(model)
  let locked = blocked is Some(_)
  @html.section(
    class="composer",
    attrs=@html.Attrs::build().aria_label("New task"),
    [
      @html.div(class="composer-head", [
        @html.h2(class="composer-heading", "New task"),
        @html.span(class="composer-stage", "Backlog"),
      ]),
      @html.div(class="composer-row", [
        @html.div(
          class="composer-input-wrap",
          on_keydown=event => {
            if event.key() == "Enter" {
              emit(SubmitRequested)
            } else if event.key() == "Escape" {
              emit(EditorCancelled)
            } else {
              @rabbita.none
            }
          },
          [
            @html.input(
              input_type=Text,
              class="composer-input",
              placeholder="Task title",
              value=editor.title,
              autofocus=true,
              attrs=@html.Attrs::build()
                .disabled(locked)
                .aria_label("Task title"),
              on_input=value => emit(TitleChanged(value)),
            ),
          ],
        ),
        @html.button(
          type_="button",
          class="btn btn-primary",
          disabled=locked || editor.title.trim().is_empty(),
          on_click=emit(SubmitRequested),
          "Create",
        ),
        @html.button(
          type_="button",
          class="btn btn-ghost",
          disabled=model.pending is Some(_),
          on_click=emit(EditorCancelled),
          "Cancel",
        ),
      ]),
      @html.details(class="composer-details", [
        @html.summary(class="composer-more", "Details"),
        @html.div(class="composer-grid", [
          labeled_field(
            "composer-priority",
            "Priority",
            @html.select(
              id="composer-priority",
              name="priority",
              disabled=locked,
              on_change=value => emit(PriorityChanged(value)),
              priorities().map(priority => {
                @html.option(
                  value=priority.to_wire(),
                  selected=priority == editor.priority,
                  priority_label(priority),
                )
              }),
            ),
          ),
          labeled_field(
            "composer-description",
            "Description",
            @html.textarea(
              id="composer-description",
              name="description",
              rows=2,
              placeholder="Optional context",
              value=editor.description,
              disabled=locked,
              on_input=value => emit(DescriptionChanged(value)),
              @html.fragment([]),
            ),
          ),
          labeled_field(
            "composer-dod",
            "Definition of done",
            @html.textarea(
              id="composer-dod",
              name="definition_of_done",
              rows=3,
              placeholder="One item per line",
              value=editor.definition_of_done,
              disabled=locked,
              on_input=value => emit(DefinitionOfDoneChanged(value)),
              @html.fragment([]),
            ),
          ),
        ]),
      ]),
      match blocked {
        Some(text) => @html.p(class="composer-hint", text)
        None => @html.nothing
      },
    ],
  )
}

///|
fn editor_panel(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  match model.editor {
    None => @html.nothing
    Some(editor) => {
      let locked = !mutations_allowed(model)
      let id = "board-editor"
      let priority_options = priorities().map(priority => {
        @html.option(
          value=priority.to_wire(),
          selected=priority == editor.priority,
          priority_label(priority),
        )
      })
      @html.section(
        class="editor",
        attrs=@html.Attrs::build().aria_label(editor_title(editor)),
        [
          @html.h2(editor_title(editor)),
          @html.div(class="editor-grid", [
            labeled_field(
              "\{id}-title",
              "Title",
              @html.input(
                input_type=Text,
                id="\{id}-title",
                name="title",
                value=editor.title,
                attrs=@html.Attrs::build().disabled(locked),
                on_input=value => emit(TitleChanged(value)),
              ),
            ),
            labeled_field(
              "\{id}-priority",
              "Priority",
              @html.select(
                id="\{id}-priority",
                name="priority",
                disabled=locked,
                on_change=value => emit(PriorityChanged(value)),
                priority_options,
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
                disabled=locked,
                on_input=value => emit(DescriptionChanged(value)),
                @html.fragment([]),
              ),
            ),
            labeled_field(
              "\{id}-dod",
              "Definition of done",
              @html.textarea(
                id="\{id}-dod",
                name="definition_of_done",
                rows=4,
                placeholder="One entry per line",
                value=editor.definition_of_done,
                disabled=locked,
                on_input=value => emit(DefinitionOfDoneChanged(value)),
                @html.fragment([]),
              ),
            ),
          ]),
          @html.div(class="editor-actions", [
            @html.button(
              type_="button",
              class="btn btn-ghost",
              disabled=locked,
              on_click=emit(EditorCancelled),
              "Cancel",
            ),
            @html.button(
              type_="button",
              class="btn btn-primary",
              disabled=locked || editor.title.trim().is_empty(),
              on_click=emit(SubmitRequested),
              match editor.mode {
                CreateMode => "Create task"
                EditMode(_) => "Save changes"
              },
            ),
          ]),
        ],
      )
    }
  }
}

///|
/// The create editor's title is used by the live region on the section.
fn editor_title(editor : Editor) -> String {
  match editor.mode {
    CreateMode => "New task"
    EditMode(task_id~) => "Edit \{task_id}"
  }
}

///|
fn task_card(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  // Mutation controls are a convenience only: suggested targets mirror the
  // Board stage FSM and the durable server stays authoritative. Opening the
  // dependency editor parks them too; one editor at a time.
  let locked = !mutations_allowed(model) || draft_open(model)
  let selected = model.selected_task == Some(task.id)
  let primary = primary_move(task.stage)
  let primary_message = if task.stage == @client.Ready && model.ticket_available {
    TicketRun(task.id)
  } else {
    MoveRequested(task.id, primary)
  }
  let primary_title = if task.stage == @client.Ready && model.ticket_available {
    "Run this ticket in the background"
  } else {
    "Move to " + ui_stage_label(primary)
  }
  let alternatives = move_suggestions(task.stage).filter(to => to != primary)
  @html.article(
    class=if selected {
      "card p-\{priority_tone(task.priority)} is-selected"
    } else {
      "card p-\{priority_tone(task.priority)}"
    },
    [
      @html.span(class="sr-only", "\{priority_label(task.priority)} priority"),
      @html.button(
        type_="button",
        class="card-title",
        title="Inspect task",
        attrs=@html.Attrs::build()
          .aria_controls("task-inspector")
          .aria_pressed(if selected { "true" } else { "false" }),
        on_click=emit(TaskSelected(task.id)),
        task.title,
      ),
      if task.description == "" {
        @html.nothing
      } else {
        @html.p(class="card-desc", task.description)
      },
      @html.div(class="card-meta", [
        @html.span(
          class="prio-text p-\{priority_tone(task.priority)}",
          priority_short(task.priority),
        ),
        @html.span(class="dot", ""),
        @html.span("\{task.dependencies.length()} deps"),
        @html.span(class="dot", ""),
        @html.span(attempt_short(model.replica, task.id)),
      ]),
      @html.div(class="card-actions", [
        card_action(
          primary_message,
          emit,
          class="btn btn-sm card-primary",
          title=primary_title,
          disabled=locked,
          label=primary_action_label(task.stage),
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
              card_action(
                EditOpened(task.id),
                emit,
                class="menu-item",
                title="Edit this task",
                disabled=locked,
                label="Edit",
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
    ],
  )
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
      class="icon-btn lane-add",
      title=match create_unavailable_hint(model) {
        Some(text) => text
        None => "New task"
      },
      disabled=!can_create(model),
      on_click=emit(CreateOpened),
      "+",
    )
  } else {
    @html.nothing
  }
  @html.section(
    class="lane",
    attrs=@html.Attrs::build().aria_labelledby("lane-\{stage.to_wire()}"),
    [
      @html.header(class="lane-head", [
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
      @html.h2("No tasks yet"),
      @html.p("Create the first task to start the board."),
      @html.button(
        type_="button",
        class="btn btn-primary",
        disabled=!can_create(model),
        on_click=emit(CreateOpened),
        "New task",
      ),
      match hint {
        None =>
          @html.p(class="empty-hint", [
            @html.kbd(class="kbd", "N"),
            @html.span(" to create"),
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
fn archive_lane(
  model : Model,
  stage : @client.ClientBoardStage,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let tasks = visible_lane_tasks(model.replica, stage, model.task_filter)
  @html.section(class="lane archive-lane", [
    @html.header(class="lane-head", [
      @html.h2(class="lane-title", [
        @html.span(ui_stage_label(stage)),
        @html.span(class="lane-count", tasks.length().to_string()),
      ]),
    ]),
    @html.div(class="lane-body", [
      if tasks.is_empty() {
        @html.p(class="lane-empty", "No tasks")
      } else {
        @html.nothing
      },
      @html.div(class="cards", tasks.map(task => task_card(model, task, emit))),
    ]),
  ])
}

///|
fn archive_drawer(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let done = visible_lane_tasks(model.replica, Done, model.task_filter)
  let paused = visible_lane_tasks(model.replica, Suspended, model.task_filter)
  if done.is_empty() && paused.is_empty() {
    return @html.nothing
  }
  @html.details(class="archive", [
    @html.summary(class="archive-summary", [
      @html.span(class="archive-title", "Archive"),
      @html.span(
        class="archive-counts",
        "\{done.length()} done · \{paused.length()} paused",
      ),
    ]),
    @html.div(class="archive-body", [
      archive_lane(model, Done, emit),
      archive_lane(model, Suspended, emit),
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
    archive_drawer(model, emit),
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
            "×",
          ),
        ],
      )
  }
}

///|
fn view(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @html.main_(class="app", [
    topbar(model, emit),
    toolbar(model, emit),
    connection_banner(model, emit),
    match model.editor {
      Some(editor) =>
        match editor.mode {
          CreateMode => composer_panel(model, editor, emit)
          EditMode(_) => editor_panel(model, emit)
        }
      None => @html.nothing
    },
    // Lanes and the inspector share one workspace. The inspector is an
    // overlay sheet, so it never squeezes the lane grid into unreadable
    // columns.
    @html.div(
      class=if inspector_open(model) || model.ticket_drawer {
        "workspace has-sheet"
      } else {
        "workspace"
      },
      [
        board(model, emit),
        inspector_panel(model, emit),
        ticket_drawer(model, emit),
      ],
    ),
    notice_toast(model.notice, emit),
  ])
}
