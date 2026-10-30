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

