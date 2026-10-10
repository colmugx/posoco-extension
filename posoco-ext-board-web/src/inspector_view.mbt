///|
fn inspector_panel(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  if model.selected_task is None &&
    model.dependency_editor is None &&
    model.attempt_draft is None &&
    model.finish_draft is None &&
    model.review_draft is None {
    return @html.nothing
  }
  @html.aside(
    id="task-inspector",
    class="inspector",
    attrs=@html.Attrs::build().aria_label("Task inspector"),
    [
      dependency_draft_banner(model, emit),
      attempt_draft_banner(model, emit),
      inspector_body(model, emit),
    ],
  )
}

///|
/// Browsing or closing the inspector must not silently discard a draft.
fn dependency_draft_banner(
  model : Model,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  guard model.dependency_editor is Some(draft) else { return @html.nothing }
  if model.selected_task == Some(draft.task_id) {
    return @html.nothing
  }
  @html.div(
    class="inspector-banner",
    attrs=@html.Attrs::build().role("status").aria_live("polite"),
    [
      @html.p(
        "Unsaved dependency draft for task \{draft.task_id} is kept while you browse other tasks.",
      ),
      @html.div(class="inspector-actions", [
        @html.button(
          type_="button",
          class="task-action",
          on_click=emit(DependencyDraftReturned),
          "Return to draft",
        ),
        @html.button(
          type_="button",
          class="task-action",
          disabled=model.pending is Some(_),
          on_click=emit(DependenciesCancelled),
          "Discard draft",
        ),
      ]),
    ],
  )
}

///|
/// Without an authoritative baseline no entity or attempt data is rendered:
/// the board is unknown, so the panel waits instead of going stale.
fn inspector_body(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  guard model.selected_task is Some(_) else { return @html.nothing }
  if !model.replica.has_snapshot() {
    return @html.section(
      class="inspector-waiting",
      attrs=@html.Attrs::build().role("status").aria_live("polite"),
      [
        @html.h2("Task inspector"),
        @html.button(
          type_="button",
          class="task-action",
          on_click=emit(InspectorClosed),
          "Close inspector",
        ),
        @html.p(
          "Waiting for Board state; task details appear after the authoritative snapshot arrives.",
        ),
      ],
    )
  }
  match inspector_task(model) {
    Some(task) => task_details(model, task, emit)
    // Transient only: revalidation clears a selection whose task is gone.
    None =>
      @html.section(class="inspector-waiting", [
        @html.h2("Task inspector"),
        @html.p("The selected task is no longer on the board."),
      ])
  }
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
  @html.section(
    class="inspector-details",
    attrs=@html.Attrs::build().aria_label("Task details"),
    [
      @html.div(class="inspector-head", [
        @html.h2(task.title),
        // Closing only clears the selection; a dependency draft survives it.
        @html.button(
          type_="button",
          class="task-action",
          title="Close inspector",
          on_click=emit(InspectorClosed),
          "Close",
        ),
      ]),
      task_fields(task),
      @html.h3("Description"),
      if task.description == "" {
        @html.p(class="inspector-empty", "No description.")
      } else {
        @html.p(task.description)
      },
      @html.h3("Definition of done"),
      task_dod(task),
      @html.h3("Dependencies"),
      task_dependencies(model, task, draft, emit),
      @html.h3("Attempts"),
      task_attempts(model, emit),
    ],
  )
}

///|
/// Read-only field grid; every timestamp the client record carries is shown.
fn task_fields(task : @client.ClientBoardTask) -> @html.Html {
  let rows = [
    @html.dt("ID"),
    @html.dd(task.id),
    @html.dt("Stage"),
    @html.dd(stage_label(task.stage)),
    @html.dt("Priority"),
    @html.dd(priority_label(task.priority)),
    @html.dt("Created"),
    @html.dd(utc_timestamp(task.created_at_ms)),
    @html.dt("Updated"),
    @html.dd(utc_timestamp(task.updated_at_ms)),
  ]
  @html.dl(
    class="inspector-fields",
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
    @html.p(class="inspector-empty", "No definition of done entries yet.")
  } else {
    @html.ul(
      class="inspector-list",
      task.definition_of_done.map(entry => @html.li(entry)),
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
        @html.p(class="inspector-empty", "No dependencies.")
      } else {
        @html.ul(
          class="inspector-list",
          task.dependencies.map(id => {
            @html.li(dependency_entry_label(dependency_title(model, id), id))
          }),
        )
      }
      @html.div(class="dependency-block", [
        list,
        @html.button(
          type_="button",
          class="task-action",
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
        class="inspector-status",
        attrs=@html.Attrs::build().role("status").aria_live("polite"),
        "Dependency draft: \{draft.dependencies.length()} selected",
      ),
      if dependency_conflict(model, draft) {
        @html.div(class="inspector-conflict", [
          @html.p(
            class="inspector-warning",
            "Dependencies changed on the board while this draft was open. Reload the latest dependencies before saving, or discard the draft.",
          ),
          @html.button(
            type_="button",
            class="task-action",
            disabled=!editable,
            on_click=emit(DependenciesRefreshed),
            "Reload latest dependencies",
          ),
        ])
      } else {
        @html.nothing
      },
      if candidates.is_empty() {
        @html.p(
          class="inspector-empty",
          "No other tasks are available as dependencies.",
        )
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
          class="inspector-list",
          missing.map(id => {
            @html.li(class="dependency-missing", [
              @html.span(
                dependency_entry_label(dependency_title(model, id), id),
              ),
              @html.button(
                type_="button",
                class="task-action",
                disabled=!editable,
                on_click=emit(DependencyToggled(id, false)),
                "Remove",
              ),
            ])
          }),
        )
      },
      @html.div(class="inspector-actions", [
        @html.button(
          type_="button",
          class="task-action",
          disabled=!editable || draft.dependencies.is_empty(),
          on_click=emit(DependenciesCleared),
          "Clear all",
        ),
        // Discarding stays possible even when the target task vanished.
        @html.button(
          type_="button",
          class="task-action",
          disabled=model.pending is Some(_),
          on_click=emit(DependenciesCancelled),
          "Discard draft",
        ),
        @html.button(
          type_="button",
          class="task-action primary",
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
    @html.p(class="inspector-empty", "No attempts yet.")
  } else {
    @html.ul(
      class="attempt-list",
      attempts.map(attempt => attempt_row(model, attempt, emit)),
    )
  }
  @html.fragment([
    @html.p(
      class="inspector-status",
      "Manual Board lifecycle only; these controls do not run an Agent or change task stage.",
    ),
    list,
    attempt_queue_form(model, emit),
    review_form(model, emit),
    finish_form(model, emit),
  ])
}

///|
fn attempt_row(
  model : Model,
  attempt : @client.ClientAttempt,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  // Status validation is live: start renders for queued attempts, review
  // recording only for a running Review attempt still pending, and the
  // explicit outcome choice for running ones; the durable server stays
  // authoritative over every transition.
  let locked = !attempt_controls_allowed(model)
  let lifecycle = match attempt.status {
    Queued =>
      [
        @html.button(
          type_="button",
          class="task-action attempt-control",
          title="Record that this queued attempt has started; no Agent is launched",
          disabled=locked,
          on_click=emit(AttemptStartRequested(attempt.id)),
          "Mark started",
        ),
      ]
    Running => {
      let actions : Array[@html.Html] = []
      if review_recordable(attempt) {
        actions.push(
          @html.button(
            type_="button",
            class="task-action attempt-control",
            title="Record Approved or Changes requested; the attempt keeps running and the decision cannot be changed",
            disabled=locked,
            on_click=emit(ReviewOpened(attempt.id)),
            "Record review decision",
          ),
        )
      }
      actions.push(
        @html.button(
          type_="button",
          class="task-action attempt-control",
          title="Choose how to finish this running attempt",
          disabled=locked,
          on_click=emit(AttemptFinishOpened(attempt.id)),
          "Finish…",
        ),
      )
      actions
    }
    Succeeded | Failed | Cancelled | Interrupted => []
  }
  @html.li(class="attempt-row", [
    @html.span(class="entity-id", attempt.id),
    @html.div(class="attempt-line", [
      @html.span(class="attempt-kind", attempt_kind_label(attempt.kind)),
      @html.span(class="attempt-state", attempt_status_label(attempt.status)),
      match attempt.review {
        Some(review) => @html.span(class="attempt-review", review_label(review))
        None => @html.nothing
      },
    ]),
    if lifecycle.is_empty() {
      @html.nothing
    } else {
      @html.div(class="attempt-actions", lifecycle)
    },
    @html.p(class="attempt-when", attempt_times(attempt)),
  ])
}

///|
/// Local queue draft: an independently generated ID plus kind, validated
/// live against the authoritative replica. Nothing here sends anything.
fn attempt_queue_form(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  match model.attempt_draft {
    None =>
      @html.button(
        type_="button",
        class="task-action",
        title="Queue a new attempt for this task",
        disabled=!attempt_controls_allowed(model),
        on_click=emit(AttemptQueueOpened),
        "Queue attempt",
      )
    Some(draft) if model.selected_task == Some(draft.task_id) => {
      let editable = attempt_draft_editable(model, draft)
      @html.div(
        class="attempt-queue",
        attrs=@html.Attrs::build().aria_label("Queue attempt"),
        [
          @html.p(
            class="inspector-status",
            attrs=@html.Attrs::build().role("status").aria_live("polite"),
            "Queue an attempt for task \{draft.task_id}.",
          ),
          @html.p(class="entity-id", "Attempt ID: \{draft.attempt_id}"),
          if !queue_attempt_id_valid(model.replica, draft.attempt_id) {
            @html.p(
              class="inspector-warning",
              "This attempt ID already exists. Discard this draft to queue a new attempt.",
            )
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
          @html.div(class="inspector-actions", [
            @html.button(
              type_="button",
              class="task-action",
              disabled=model.pending is Some(_),
              on_click=emit(AttemptQueueCancelled),
              "Cancel",
            ),
            @html.button(
              type_="button",
              class="task-action primary",
              disabled=!attempt_queue_submit_allowed(model, draft),
              on_click=emit(AttemptQueueSubmitted),
              "Queue attempt",
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
fn padded(value : Int64, width : Int) -> String {
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
fn attempt_draft_banner(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let (task_id, label, return_msg, cancel) = match
    (model.attempt_draft, model.finish_draft, model.review_draft) {
    (Some(draft), _, _) =>
      (draft.task_id, "attempt", AttemptDraftReturned, AttemptQueueCancelled)
    (_, Some(draft), _) =>
      (draft.task_id, "attempt", AttemptDraftReturned, AttemptFinishCancelled)
    (_, _, Some(draft)) =>
      (draft.task_id, "review", ReviewDraftReturned, ReviewCancelled)
    _ => return @html.nothing
  }
  if model.selected_task == Some(task_id) {
    return @html.nothing
  }
  @html.div(class="inspector-banner", [
    @html.p(
      "Unsaved \{label} draft for task \{task_id} is kept while you browse.",
    ),
    @html.div(class="inspector-actions", [
      @html.button(
        type_="button",
        class="task-action",
        on_click=emit(return_msg),
        "Return to draft",
      ),
      @html.button(
        type_="button",
        class="task-action",
        disabled=model.pending is Some(_),
        on_click=emit(cancel),
        "Discard draft",
      ),
    ]),
  ])
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
      @html.p("Finish attempt \{draft.attempt_id}"),
      // A running Review attempt without a recorded decision warns but
      // never blocks: finishing and recording stay independent commands.
      match attempt_by_id(model.replica, draft.attempt_id) {
        Some(attempt) if finish_review_warning(attempt) is Some(warning) =>
          @html.p(class="inspector-warning", warning)
        _ => @html.nothing
      },
      if !editable && model.pending is None && mutations_allowed(model) {
        @html.p(
          class="inspector-warning",
          "This attempt is no longer running. Discard this draft; no command was resent.",
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
      @html.div(class="inspector-actions", [
        @html.button(
          type_="button",
          class="task-action",
          disabled=model.pending is Some(_),
          on_click=emit(AttemptFinishCancelled),
          "Discard draft",
        ),
        @html.button(
          type_="button",
          class="task-action primary",
          disabled=!finish_submit_allowed(model, draft),
          on_click=emit(AttemptFinishSubmitted),
          "Finish attempt",
        ),
      ]),
    ],
  )
}

///|
/// Local review draft: only the target attempt's ID plus an explicit
/// decision that starts absent. Nothing here sends anything; submission is
/// a separate explicit action through the shared single-pending gate. The
/// recorded decision is final on the server, so the irreversibility notice
/// stays visible while the draft is open.
fn review_form(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  guard model.review_draft is Some(draft) &&
    model.selected_task == Some(draft.task_id) else {
    return @html.nothing
  }
  let editable = review_draft_editable(model, draft)
  @html.section(
    class="attempt-queue",
    attrs=@html.Attrs::build().aria_label("Record review decision"),
    [
      @html.p("Record review decision for attempt \{draft.attempt_id}"),
      match attempt_by_id(model.replica, draft.attempt_id) {
        Some(attempt) =>
          @html.dl(class="inspector-fields", [
            @html.dt("Current attempt status"),
            @html.dd(attempt_status_label(attempt.status)),
            @html.dt("Current review decision"),
            @html.dd(
              match attempt.review {
                Some(decision) => review_label(decision)
                None => "No review decision"
              },
            ),
          ])
        None =>
          @html.p(
            class="inspector-empty",
            "Waiting for authoritative attempt state.",
          )
      },
      @html.p(
        class="inspector-status",
        attrs=@html.Attrs::build().role("status").aria_live("polite"),
        "Recording never changes the attempt status or the task stage.",
      ),
      if !editable && model.pending is None && mutations_allowed(model) {
        @html.p(
          class="inspector-warning",
          "This attempt can no longer record a review decision. Discard this draft; no command was sent.",
        )
      } else {
        @html.nothing
      },
      labeled_field(
        "review-record-decision",
        "Decision",
        @html.select(
          id="review-record-decision",
          name="review_decision",
          disabled=!editable,
          on_change=value => emit(ReviewDecisionChanged(value)),
          [
            @html.option(
              value="",
              selected=draft.decision is None,
              "Choose a decision…",
            ),
            ..review_decisions().map(decision => {
              @html.option(
                value=decision.to_wire(),
                selected=draft.decision == Some(decision),
                review_decision_label(decision),
              )
            }),
          ],
        ),
      ),
      @html.p(
        class="inspector-status",
        "A recorded decision is final; it cannot be changed or cleared.",
      ),
      @html.div(class="inspector-actions", [
        @html.button(
          type_="button",
          class="task-action",
          disabled=model.pending is Some(_),
          on_click=emit(ReviewCancelled),
          "Discard draft",
        ),
        @html.button(
          type_="button",
          class="task-action primary",
          disabled=!review_submit_allowed(model, draft),
          on_click=emit(ReviewSubmitted),
          "Record decision",
        ),
      ]),
    ],
  )
}
