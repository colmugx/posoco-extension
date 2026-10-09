///|
fn inspector_panel(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  if model.selected_task is None && model.dependency_editor is None {
    return @html.nothing
  }
  @html.aside(
    id="task-inspector",
    class="inspector",
    attrs=@html.Attrs::build().aria_label("Task inspector"),
    [dependency_draft_banner(model, emit), inspector_body(model, emit)],
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
      task_attempts(model),
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
          disabled=model.editor is Some(_) ||
            model.dependency_editor is Some(_) ||
            !mutations_allowed(model),
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
/// Read-only attempt history straight from the authoritative replica; no
/// execution or management controls are offered here.
fn task_attempts(model : Model) -> @html.Html {
  let attempts = inspector_attempts(model)
  if attempts.is_empty() {
    return @html.p(class="inspector-empty", "No attempts yet.")
  }
  @html.ul(
    class="attempt-list",
    attempts.map(attempt => {
      @html.li(class="attempt-row", [
        @html.span(class="entity-id", attempt.id),
        @html.div(class="attempt-line", [
          @html.span(class="attempt-kind", attempt_kind_label(attempt.kind)),
          @html.span(
            class="attempt-state",
            attempt_status_label(attempt.status),
          ),
          match attempt.review {
            Some(review) =>
              @html.span(class="attempt-review", review_label(review))
            None => @html.nothing
          },
        ]),
        @html.p(class="attempt-when", attempt_times(attempt)),
      ])
    }),
  )
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
