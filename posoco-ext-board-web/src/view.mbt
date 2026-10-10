///|
/// One card action button. Card actions stop click propagation: activating
/// Edit or a suggested move must not also trigger the card's
/// select-to-inspect handler on the surrounding article.
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
fn task_card(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let replica = model.replica
  // Mutation controls are a convenience only: suggested targets mirror the
  // Board stage FSM and the durable server stays authoritative. Opening the
  // dependency editor parks them too; one editor at a time.
  let locked = !mutations_allowed(model) || draft_open(model)
  let selected = model.selected_task == Some(task.id)
  let moves = move_suggestions(task.stage).map(to => {
    card_action(
      MoveRequested(task.id, to),
      emit,
      class="task-action move",
      title="Move to \{stage_label(to)}",
      disabled=locked,
      label="→ \{stage_label(to)}",
    )
  })
  @html.article(
    class=if selected { "task-card is-selected" } else { "task-card" },
    attrs=@html.Attrs::build().on_click(_ => emit(TaskSelected(task.id))),
    [
      @html.div(class="task-topline", [
        @html.span(class="priority", priority_label(task.priority)),
        @html.span(class="entity-id", task.id),
      ]),
      // The full-width title button is the selection control: keyboard
      // activation and assistive tech get real button semantics with an
      // aria-pressed marker, and no control is nested inside another.
      @html.h3([
        @html.button(
          type_="button",
          class="task-select",
          title="Inspect task",
          attrs=@html.Attrs::build()
            .aria_controls("task-inspector")
            .aria_pressed(if selected { "true" } else { "false" }),
          on_click=emit(TaskSelected(task.id)),
          task.title,
        ),
      ]),
      @html.p(class="description", task.description),
      @html.p(
        class="task-meta",
        "\{task.dependencies.length()} dependencies · \{attempt_count(replica, task.id)} attempts",
      ),
      @html.p(class="attempt-status", attempt_indicator(replica, task.id)),
      @html.div(
        class="task-actions",
        [
          card_action(
            EditOpened(task.id),
            emit,
            class="task-action",
            title="Edit this task",
            disabled=locked,
            label="Edit",
          ),
          ..moves,
        ],
      ),
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
  let tasks = tasks_in_lane(replica, stage)
  @html.section(class="lane", [
    @html.h2("\{stage_label(stage)} · \{tasks.length()}"),
    @html.div(class="cards", tasks.map(task => task_card(model, task, emit))),
  ])
}

///|
/// Every mutation control shares one disabled state: the shell only accepts
/// input while the replica is authoritative, the connection is online, no
/// command is in flight and no editor holds a draft.
fn new_task_button(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @html.button(
    type_="button",
    class="new-task",
    disabled=!mutations_allowed(model) || draft_open(model),
    on_click=emit(CreateOpened),
    "New task",
  )
}

///|
/// The mutation notice is a live region fed exclusively with mapped safe
/// text; wire codes, store and protocol details never reach this element.
fn notice_region(notice : Notice?) -> @html.Html {
  match notice {
    None => @html.nothing
    Some(value) =>
      @html.p(
        class="notice \{notice_class(value.severity)}",
        attrs=@html.Attrs::build().aria_live("polite"),
        value.text,
      )
  }
}

///|
fn editor_title(editor : Editor) -> String {
  match editor.mode {
    CreateMode => "New task"
    EditMode(task_id~) => "Edit task \{task_id}"
  }
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
              class="secondary",
              disabled=locked,
              on_click=emit(EditorCancelled),
              "Cancel",
            ),
            @html.button(
              type_="button",
              class="primary",
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
fn view(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  let replica = model.replica
  let empty = match empty_message(replica) {
    Some(message) => [@html.p(class="empty-state", message)]
    None => []
  }
  @html.main_(class="board-shell", [
    @html.header(class="board-header", [
      @html.h1("Board"),
      @html.span(class="connection", connection_label(model.connection)),
      @html.p(
        class="board-meta",
        "Revision \{replica.revision()} · Stream \{replica.last_seq()} · \{replica.tasks().length()} tasks",
      ),
      new_task_button(model, emit),
    ]),
    @html.p(
      class="status",
      attrs=@html.Attrs::build().role("status").aria_live("polite"),
      if model.pending is Some(_) {
        "Saving change; waiting for authoritative confirmation."
      } else if !replica.has_snapshot() {
        "Waiting for authoritative Board state"
      } else {
        model.last_status
      },
    ),
    notice_region(model.notice),
    editor_panel(model, emit),
    // Lanes and the inspector share one responsive body grid; the panel is
    // a sibling of the lanes, never nested inside them.
    @html.div(
      class=if model.selected_task is Some(_) ||
        model.dependency_editor is Some(_) ||
        model.attempt_draft is Some(_) ||
        model.finish_draft is Some(_) ||
        model.review_draft is Some(_) {
        "board-body has-inspector"
      } else {
        "board-body"
      },
      [
        @html.div(class="board-main", [
          @html.div(empty),
          @html.div(
            class="lanes",
            lanes().map(stage => lane(model, stage, emit)),
          ),
        ]),
        inspector_panel(model, emit),
      ],
    ),
  ])
}
