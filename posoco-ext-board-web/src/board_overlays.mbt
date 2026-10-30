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

