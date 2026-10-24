///|
/// Level two of the board: one task, its position in the pipeline, the next
/// step, its review, and its history. Rendered as a native dialog so the
/// browser owns Esc, focus and the backdrop.
fn detail_dialog(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @html.dialog(
    id="detail-dialog",
    class="dialog sheet-dialog",
    on_close=_ => emit(InspectorClosed),
    attrs=@html.Attrs::build().aria_label("Task detail"),
    [@html.div(class="sheet", [detail_body(model, emit)])],
  )
}

///|
fn detail_body(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  guard model.selected_task is Some(_) else {
    return @html.div(class="sheet-empty", [
      @html.p("No task is open."),
    ])
  }
  if !model.replica.has_snapshot() {
    return @html.div(class="sheet-head", [
      @html.h2(class="sheet-title", "Waiting for the board"),
      close_button("detail-dialog"),
    ])
  }
  match inspector_task(model) {
    Some(task) => task_details(model, task, emit)
    None =>
      @html.div(class="sheet-head", [
        @html.h2(class="sheet-title", "This task is no longer on the board"),
        close_button("detail-dialog"),
      ])
  }
}

///|
fn sheet_crumb(task : @client.ClientBoardTask) -> @html.Html {
  @html.nav(
    class="crumbs",
    attrs=@html.Attrs::build().aria_label("Breadcrumb"),
    [
      @html.button(
        type_="button",
        class="crumb-link",
        attrs=@html.Attrs::build().on_click(_ => {
          ui_close("detail-dialog")
          @rabbita.none
        }),
        "Board",
      ),
      @html.span(class="crumb-sep", "/"),
      @html.span(class="crumb-here", ui_stage_label(task.stage)),
    ],
  )
}

///|
/// The fixed note a cancelled task carries instead of a next action.
fn cancelled_note() -> String {
  "Cancelled; kept for history."
}

///|
/// The next move, expressed as the person's intent, plus the reason it is
/// unavailable when it is. The primary intent mirrors the card exactly.
fn detail_next_action(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  // Cancelled is terminal: there is no next action to offer, only the note
  // that explains why the task stayed on the board.
  if !has_primary_intent(task.stage) {
    return @html.section(class="next-block", [
      @html.p(class="next-note is-terminal", cancelled_note()),
    ])
  }
  let hint = action_blocked_hint(model, task.id)
  let locked = hint is Some(_) || model.pending is Some(_)
  let note = match hint {
    Some(text) => text
    None =>
      match task.stage {
        Created =>
          if model.ticket_available {
            "Clarifies the ticket and its acceptance criteria."
          } else {
            "Moves to Shaping for scoping."
          }
        Refining => "Marks it scoped and ready to be picked up."
        Ready =>
          if model.ticket_available {
            "Starts a worker session in the background."
          } else {
            "Moves it to In progress."
          }
        Running => "Asks for a review before closing."
        Review => "Closes the task. Done is final and moves it to the archive."
        Done => "Sends a closed task back to Shaping."
        Suspended => "Returns a paused task to Ready."
        Cancelled => cancelled_note()
      }
  }
  @html.section(class="next-block", [
    primary_intent(
      model,
      task,
      emit,
      disabled=locked,
      class="btn btn-primary btn-lg next-primary",
    ),
    @html.p(
      class=if hint is Some(_) { "next-note is-warn" } else { "next-note" },
      note,
    ),
  ])
}

///|
/// The ticket's model: the compact chip plus, when the host offers a
/// selectable catalog, the slot/effort picker. `Inherit current` is both the
/// default and the explicit clear action, and nothing here changes state
/// optimistically: the controls keep rendering the authoritative task model
/// until the host answers.
fn model_block(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let catalog = ticket_model_catalog(model)
  @html.section(class="detail-section model-section", [
    @html.h2(class="section-title", "Model"),
    model_chip(catalog, task.model),
    if !catalog.selectable {
      // Keep the pinned model visible read-only instead of hiding the fact
      // that this host cannot offer a picker.
      @html.p(class="section-note", model_unavailable_note(task.model))
    } else {
      model_picker(model, task, catalog, emit)
    },
  ])
}

///|
/// One model per ticket. The slot select takes stable slot ids as values, and
/// the effort select only appears once the chosen slot advertises efforts.
fn model_picker(
  model : Model,
  task : @client.ClientBoardTask,
  catalog : ModelCatalog,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let blocked = model_picker_blocked(model, task.id)
  let locked = blocked is Some(_)
  let selection = task.model
  let pinned = match selection {
    Some(selection) => catalog.find(selection.slot)
    None => None
  }
  let effort = match pinned {
    Some(option) =>
      if option.efforts.length() == 0 {
        @html.nothing
      } else {
        labeled_field(
          "ticket-model-effort",
          "Effort",
          @html.select(
            id="ticket-model-effort",
            name="ticket_model_effort",
            disabled=locked,
            on_change=value => emit(TicketSetModel(task.id, Some(model_choice_with_effort(option.id, value)))),
            model_select_html(model_effort_options(option, match selection {
              Some(selection) => selection.effort
              None => None
            })),
          ),
        )
      }
    None => @html.nothing
  }
  @html.div(class="model-picker", [
    labeled_field(
      "ticket-model-slot",
      "Model",
      @html.select(
        id="ticket-model-slot",
        name="ticket_model",
        disabled=locked,
        on_change=value => emit(TicketSetModel(task.id, model_choice_from_slot(value))),
        model_select_html(model_slot_options(catalog, selection)),
      ),
    ),
    effort,
    @html.p(
      class=if locked {
        "model-picker-note is-warn"
      } else {
        "model-picker-note"
      },
      attrs=@html.Attrs::build().role("status").aria_live("polite"),
      match blocked {
        Some(text) => text
        None =>
          "Inherit follows the current Cetas model. A pinned model keeps its slot and effort."
      },
    ),
  ])
}

///|
/// Review is the moment the pipeline exists for: a recorded decision is
/// final, so it is confirmed and never bundled with the move.
fn review_block(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  match task.stage {
    Review | Done => ()
    _ => return @html.nothing
  }
  let attempts = inspector_attempts(model)
  let open = attempts.filter(review_recordable)
  let recordable = open.get(open.length() - 1)
  let decided = attempts
    .filter(attempt => attempt.review is Some(Approved) || attempt.review is Some(ChangesRequested))
    .get(0)
  let locked = !attempt_controls_allowed(model)
  @html.section(class="detail-section", [
    @html.h2(class="section-title", "Review"),
    match recordable {
      Some(attempt) =>
        @html.div(class="review-open", [
          @html.p(class="review-meta", [
            @html.span(class="mono", attempt.id),
            @html.span(class="review-state", "running"),
            @html.span(class="review-pending", "decision pending"),
          ]),
          @html.div(class="review-actions", [
            @html.button(
              type_="button",
              class="btn btn-primary",
              disabled=locked,
              attrs=@html.Attrs::build().on_click(_ => {
                ui_show("confirm-dialog")
                emit(ReviewDecide(attempt.id, "approved"))
              }),
              "Approve",
            ),
            @html.button(
              type_="button",
              class="btn",
              disabled=locked,
              attrs=@html.Attrs::build().on_click(_ => {
                ui_show("confirm-dialog")
                emit(ReviewDecide(attempt.id, "changes_requested"))
              }),
              "Request changes",
            ),
          ]),
          @html.p(
            class="section-note",
            "A recorded decision is final. It does not move the task: close it with the action above.",
          ),
        ])
      None =>
        match decided {
          Some(attempt) =>
            @html.p(class="review-meta", [
              @html.span(class="review-state is-decided", review_label(attempt.review.unwrap_or(Pending))),
              @html.span(class="mono", attempt.id),
            ])
          None =>
            @html.p(
              class="section-note",
              "No review attempt is recording a decision. Close the task with the action above, or send it back to Ready.",
            )
        }
    },
  ])
}

///|
fn task_details(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let draft = match model.dependency_editor {
    Some(draft) if draft.task_id == task.id => Some(draft)
    _ => None
  }
  @html.fragment([
    @html.header(class="sheet-head", [
      @html.div(class="sheet-heading", [
        sheet_crumb(task),
        @html.h2(id="task-detail", class="sheet-title", task.title),
        @html.p(class="sheet-meta", [
          @html.span(class="chip", priority_short(task.priority) + " " + priority_label(task.priority)),
          @html.span(class="chip", ui_stage_label(task.stage)),
          model_chip(ticket_model_catalog(model), task.model),
          @html.span(class="chip is-quiet", task.id),
        ]),
      ]),
      @html.div(class="sheet-head-actions", [
        @html.button(
          type_="button",
          class="btn btn-sm",
          title="Open this ticket's activity",
          attrs=@html.Attrs::build().on_click(_ => {
            ui_show("ticket-activity-dialog")
            emit(TicketActivityOpened(task.id))
          }),
          "Activity",
        ),
        close_button("detail-dialog"),
      ]),
    ]),
    @html.div(class="sheet-body", [
      stage_stepper(model, task, emit),
      detail_next_action(model, task, emit),
      model_block(model, task, emit),
      review_block(model, task, emit),
      @html.section(class="detail-section", [
        @html.h2(class="section-title", "Definition of done"),
        task_dod(task),
      ]),
      @html.section(class="detail-section", [
        @html.h2(class="section-title", "Dependencies"),
        task_dependencies(model, task, draft, emit),
      ]),
      @html.section(class="detail-section", [
        @html.h2(class="section-title", "Runs"),
        @html.p(
          class="section-note",
          "Manual records: the board tracks the attempt, it does not run it.",
        ),
        task_attempts(model, emit),
      ]),
      @html.details(id="inspector-task-details", class="detail-fold", [
        @html.summary(class="fold-summary", "Description and details"),
        if task.description == "" {
          @html.p(class="empty-line", "No description.")
        } else {
          @html.p(class="detail-description", task.description)
        },
        task_fields(task),
      ]),
    ]),
  ])
}

///|
/// Read-only field grid for the collapsed Details section. Stage and priority
/// live in the sheet header, so they are not repeated here.
fn task_fields(task : @client.ClientBoardTask) -> @html.Html {
  let rows = [
    @html.dt("Created"),
    @html.dd(utc_timestamp(task.created_at_ms)),
    @html.dt("Updated"),
    @html.dd(utc_timestamp(task.updated_at_ms)),
  ]
  @html.dl(
    class="detail-fields",
    match task.ready_since_ms {
      Some(at_ms) =>
        [..rows, @html.dt("Ready since"), @html.dd(utc_timestamp(at_ms))]
      None => rows
    },
  )
}

///|
fn task_dod(task : @client.ClientBoardTask) -> @html.Html {
  if task.definition_of_done.is_empty() {
    @html.p(class="empty-line", "No definition of done yet.")
  } else {
    @html.ul(
      class="checklist",
      task.definition_of_done.map(entry => @html.li(class="check", entry)),
    )
  }
}

///|
/// Read-only dependency listing with titles resolved live from the replica;
/// when the draft editor is open the interactive panel replaces this list.
fn task_dependencies(
  model : Model,
  task : @client.ClientBoardTask,
  draft : DependencyDraft?,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  match draft {
    Some(draft) => dependency_editor_panel(model, draft, emit)
    None => {
      let list = if task.dependencies.is_empty() {
        @html.p(class="empty-line", "No dependencies.")
      } else {
        @html.ul(
          class="plain-list",
          task.dependencies.map(id => {
            @html.li(dependency_entry_label(dependency_title(model, id), id))
          }),
        )
      }
      @html.div(class="dependency-block", [
        list,
        @html.button(
          type_="button",
          class="btn btn-sm",
          title="Edit this task's dependencies in a local draft",
          // Only one editor at a time, and only through the mutation gate.
          disabled=draft_open(model) || !mutations_allowed(model),
          on_click=emit(DependenciesOpened),
          "Edit dependencies",
        ),
      ])
    }
  }
}

///|
/// Local dependency draft editor. Checkboxes exclude the task itself because
/// the candidate list is pre-filtered; ids missing from the board stay
/// visible with an explicit remove control instead of being silently
/// dropped. Nothing here sends anything: saving is a separate explicit
/// action, and an external relationship change blocks it behind a reload.
fn dependency_editor_panel(
  model : Model,
  draft : DependencyDraft,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let editable = dependency_editable(model, draft)
  let candidates = dependency_candidates(model, draft.task_id)
  let missing = draft.dependencies.filter(id => {
    !candidates.any(candidate => candidate.id == id)
  })
  @html.section(
    class="dependency-editor",
    attrs=@html.Attrs::build().aria_label("Edit dependencies"),
    [
      @html.p(
        class="section-note",
        attrs=@html.Attrs::build().role("status").aria_live("polite"),
        "Draft: \{draft.dependencies.length()} selected",
      ),
      if dependency_conflict(model, draft) {
        @html.div(class="callout is-warn", [
          @html.p(
            "Dependencies changed on the board while this draft was open. Reload the latest dependencies before saving, or discard the draft.",
          ),
          @html.button(
            type_="button",
            class="btn btn-sm",
            disabled=!editable,
            on_click=emit(DependenciesRefreshed),
            "Reload latest dependencies",
          ),
        ])
      } else {
        @html.nothing
      },
      if candidates.is_empty() {
        @html.p(class="empty-line", "No other tasks are available as dependencies.")
      } else {
        @html.nothing
      },
      @html.div(
        class="dependency-options",
        candidates.map(candidate => {
          let checked = draft.dependencies.contains(candidate.id)
          @html.label(
            class="dependency-option",
            for_="dependency-\{candidate.id}",
            [
              // Rabbita reports the input value, not checked state. Toggle
              // the current draft in update, not a captured render-time value.
              @html.input(
                input_type=Checkbox,
                id="dependency-\{candidate.id}",
                name="dependency",
                value=candidate.id,
                checked~,
                // Rabbita's `input` has no disabled parameter; the attribute
                // builder is the supported way to disable it.
                attrs=@html.Attrs::build().disabled(!editable),
                on_change=_ => emit(DependencySelectionChanged(candidate.id)),
              ),
              @html.span(dependency_entry_label(candidate.title, candidate.id)),
            ],
          )
        }),
      ),
      if missing.is_empty() {
        @html.nothing
      } else {
        @html.ul(
          class="plain-list",
          missing.map(id => {
            @html.li(class="dependency-missing", [
              @html.span(dependency_entry_label(dependency_title(model, id), id)),
              @html.button(
                type_="button",
                class="btn btn-sm",
                disabled=!editable,
                on_click=emit(DependencyToggled(id, false)),
                "Remove",
              ),
            ])
          }),
        )
      },
      @html.div(class="button-row", [
        @html.button(
          type_="button",
          class="btn",
          disabled=!editable || draft.dependencies.is_empty(),
          on_click=emit(DependenciesCleared),
          "Clear all",
        ),
        @html.button(
          type_="button",
          class="btn",
          disabled=model.pending is Some(_),
          on_click=emit(DependenciesCancelled),
          "Discard draft",
        ),
        @html.button(
          type_="button",
          class="btn btn-primary",
          disabled=!dependency_save_allowed(model, draft),
          on_click=emit(DependenciesSubmitted),
          "Save dependencies",
        ),
      ]),
    ],
  )
}

///|
/// Authoritative attempt history plus manual lifecycle controls. The
/// controls only send queue/start/finish/review commands through the shared
/// single-pending gate; execution and retries stay out.
fn task_attempts(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let attempts = inspector_attempts(model)
  let list = if attempts.is_empty() {
    @html.p(class="empty-line", "No runs yet.")
  } else {
    @html.ul(
      class="attempt-list",
      attempts.map(attempt => attempt_row(model, attempt, emit)),
    )
  }
  @html.fragment([
    list,
    attempt_queue_form(model, emit),
    finish_form(model, emit),
  ])
}

///|
fn attempt_row(
  model : Model,
  attempt : @client.ClientAttempt,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  // Status validation is live: start renders for queued attempts, and the
  // explicit outcome choice for running ones; the durable server stays
  // authoritative over every transition.
  let locked = !attempt_controls_allowed(model)
  let lifecycle = match attempt.status {
    Queued =>
      [
        @html.button(
          type_="button",
          class="btn btn-sm",
          title="Record that this queued attempt has started; no Agent is launched",
          disabled=locked,
          on_click=emit(AttemptStartRequested(attempt.id)),
          "Mark started",
        ),
      ]
    Running =>
      [
        @html.button(
          type_="button",
          class="btn btn-sm",
          title="Choose how to finish this running attempt",
          disabled=locked,
          on_click=emit(AttemptFinishOpened(attempt.id)),
          "Finish…",
        ),
      ]
    Succeeded | Failed | Cancelled | Interrupted => []
  }
  @html.li(class="attempt-row", [
    @html.div(class="attempt-line", [
      @html.span(class="mono", attempt.id),
      @html.span(class="attempt-kind", attempt_kind_label(attempt.kind)),
      @html.span(class="state-chip is-\{attempt_state_tone(attempt.status)}", attempt_status_label(attempt.status)),
      match attempt.review {
        Some(review) =>
          @html.span(class="attempt-review", review_label(review))
        None => @html.nothing
      },
    ]),
    if lifecycle.is_empty() {
      @html.nothing
    } else {
      @html.div(class="button-row", lifecycle)
    },
    @html.p(class="attempt-when", attempt_times(attempt)),
  ])
}

///|
fn attempt_state_tone(status : @client.ClientAttemptStatus) -> String {
  match status {
    Queued => "queued"
    Running => "running"
    Succeeded => "ok"
    Failed => "bad"
    Cancelled | Interrupted => "muted"
  }
}

///|
/// Local queue draft: an independently generated ID plus kind, validated
/// live against the authoritative replica. Nothing here sends anything.
fn attempt_queue_form(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  match model.attempt_draft {
    None =>
      @html.button(
        type_="button",
        class="btn btn-sm",
        title="Open a local queue draft for this task",
        disabled=!attempt_controls_allowed(model),
        on_click=emit(AttemptQueueOpened),
        "Queue run…",
      )
    Some(draft) if model.selected_task == Some(draft.task_id) => {
      let editable = attempt_draft_editable(model, draft)
      @html.div(
        class="attempt-queue",
        attrs=@html.Attrs::build().aria_label("Queue run"),
        [
          @html.p(class="section-note", "Queue a run for task \{draft.task_id}."),
          @html.p(class="mono attempt-id", draft.attempt_id),
          if !queue_attempt_id_valid(model.replica, draft.attempt_id) {
            @html.p(class="callout is-warn", "This run ID already exists. Discard this draft to queue a new run.")
          } else {
            @html.nothing
          },
          labeled_field(
            "attempt-queue-kind",
            "Kind",
            @html.select(
              id="attempt-queue-kind",
              name="attempt_kind",
              disabled=!editable,
              on_change=value => emit(AttemptKindChanged(value)),
              attempt_kinds().map(kind => {
                @html.option(
                  value=kind.to_wire(),
                  selected=kind == draft.kind,
                  attempt_kind_label(kind),
                )
              }),
            ),
          ),
          @html.div(class="button-row", [
            @html.button(
              type_="button",
              class="btn",
              disabled=model.pending is Some(_),
              on_click=emit(AttemptQueueCancelled),
              "Cancel",
            ),
            @html.button(
              type_="button",
              class="btn btn-primary",
              disabled=!attempt_queue_submit_allowed(model, draft),
              on_click=emit(AttemptQueueSubmitted),
              "Queue run",
            ),
          ]),
        ],
      )
    }
    Some(_) => @html.nothing
  }
}

///|
/// Only the timestamps the record actually carries are rendered.
fn attempt_times(attempt : @client.ClientAttempt) -> String {
  let parts = match attempt.started_at_ms {
    Some(at_ms) =>
      [
        "created \{utc_timestamp(attempt.created_at_ms)}",
        "started \{utc_timestamp(at_ms)}",
      ]
    None => ["created \{utc_timestamp(attempt.created_at_ms)}"]
  }
  let parts = match attempt.finished_at_ms {
    Some(at_ms) => [..parts, "finished \{utc_timestamp(at_ms)}"]
    None => parts
  }
  [..parts, "updated \{utc_timestamp(attempt.updated_at_ms)}"].join(" · ")
}

///|
fn attempt_kind_label(kind : @client.ClientAttemptKind) -> String {
  match kind {
    Discuss => "Discuss"
    Execute => "Execute"
    Review => "Review"
  }
}

///|
fn attempt_status_label(status : @client.ClientAttemptStatus) -> String {
  match status {
    Queued => "Queued"
    Running => "Running"
    Succeeded => "Succeeded"
    Failed => "Failed"
    Cancelled => "Cancelled"
    Interrupted => "Interrupted"
  }
}

///|
fn review_label(review : @client.ClientReviewDecision) -> String {
  match review {
    Pending => "Review pending"
    Approved => "Review approved"
    ChangesRequested => "Review changes requested"
  }
}

///|
/// Dependencies always render as "title (id)" so ids stay visible even when
/// titles are not unique or the task is unavailable.
fn dependency_entry_label(title : String, id : String) -> String {
  "\{title} (\{id})"
}

///|
/// UTC civil date from days since 1970-01-01 (proleptic Gregorian).
fn civil_from_days(days : Int64) -> (Int64, Int64, Int64) {
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  (if m <= 2L { y + 1L } else { y }, m, d)
}

///|
/// Epoch milliseconds as "YYYY-MM-DD HH:MM:SS UTC". Pure formatting keeps
/// the inspector free of host clock APIs and new dependencies.
fn utc_timestamp(ms : Int64) -> String {
  let days = ms / 86400000L -
    (if ms < 0L && ms % 86400000L != 0L { 1L } else { 0L })
  let (year, month, day) = civil_from_days(days)
  let seconds = (ms % 86400000L + 86400000L) % 86400000L / 1000L
  "\{padded(year, 4)}-\{padded(month, 2)}-\{padded(day, 2)} \{padded(seconds / 3600L, 2)}:\{padded(seconds % 3600L / 60L, 2)}:\{padded(seconds % 60L, 2)} UTC"
}

///|
fn padded(value : Int64, width : Int32) -> String {
  let digits = value.to_string()
  let pad = width - digits.length()
  if pad <= 0 {
    digits
  } else {
    let mut zeros = ""
    for _ in 0..<pad {
      zeros = zeros + "0"
    }
    zeros + digits
  }
}

///|
fn finish_form(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  guard model.finish_draft is Some(draft) &&
    model.selected_task == Some(draft.task_id) else {
    return @html.nothing
  }
  let editable = finish_draft_editable(model, draft)
  @html.section(
    class="attempt-queue",
    attrs=@html.Attrs::build().aria_label("Finish attempt"),
    [
      @html.p(class="section-note", "Finish run \{draft.attempt_id}"),
      // A running Review attempt without a recorded decision warns but
      // never blocks: finishing and recording stay independent commands.
      match attempt_by_id(model.replica, draft.attempt_id) {
        Some(attempt) if finish_review_warning(attempt) is Some(warning) =>
          @html.p(class="callout is-warn", warning)
        _ => @html.nothing
      },
      if !editable && model.pending is None && mutations_allowed(model) {
        @html.p(
          class="callout is-warn",
          attrs=@html.Attrs::build().role("status").aria_live("polite"),
          "This run is no longer running. Discard this draft; no command was resent.",
        )
      } else {
        @html.nothing
      },
      labeled_field(
        "attempt-finish-outcome",
        "Terminal outcome",
        @html.select(
          id="attempt-finish-outcome",
          name="attempt_outcome",
          disabled=!editable,
          on_change=value => emit(AttemptOutcomeChanged(value)),
          [
            @html.option(
              value="",
              selected=draft.outcome is None,
              "Choose an outcome…",
            ),
            ..attempt_outcomes().map(outcome => {
              @html.option(
                value=outcome.to_wire(),
                selected=draft.outcome == Some(outcome),
                outcome_label(outcome),
              )
            }),
          ],
        ),
      ),
      @html.div(class="button-row", [
        @html.button(
          type_="button",
          class="btn",
          disabled=model.pending is Some(_),
          on_click=emit(AttemptFinishCancelled),
          "Discard draft",
        ),
        @html.button(
          type_="button",
          class="btn btn-primary",
          disabled=!finish_submit_allowed(model, draft),
          on_click=emit(AttemptFinishSubmitted),
          "Finish run",
        ),
      ]),
    ],
  )
}
