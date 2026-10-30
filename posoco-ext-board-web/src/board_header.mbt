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

