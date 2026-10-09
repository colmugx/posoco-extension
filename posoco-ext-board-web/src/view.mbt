///|
fn task_card(
  model : Model,
  task : @client.ClientBoardTask,
  emit : @rabbita.Emit[Msg],
) -> @html.Html {
  let replica = model.replica
  // Mutation controls are a convenience only: suggested targets mirror the
  // Board stage FSM and the durable server stays authoritative.
  let locked = !mutations_allowed(model) || model.editor is Some(_)
  let moves = move_suggestions(task.stage).map(to => {
    @html.button(
      type_="button",
      class="task-action move",
      title="Move to \{stage_label(to)}",
      disabled=locked,
      on_click=emit(MoveRequested(task.id, to)),
      "→ \{stage_label(to)}",
    )
  })
  @html.article(class="task-card", [
    @html.div(class="task-topline", [
      @html.span(class="priority", priority_label(task.priority)),
      @html.span(class="entity-id", task.id),
    ]),
    @html.h3(task.title),
    @html.p(class="description", task.description),
    @html.p(
      class="task-meta",
      "\{task.dependencies.length()} dependencies · \{attempt_count(replica, task.id)} attempts",
    ),
    @html.p(class="attempt-status", attempt_indicator(replica, task.id)),
    @html.div(
      class="task-actions",
      [
        @html.button(
          type_="button",
          class="task-action",
          disabled=locked,
          on_click=emit(EditOpened(task.id)),
          "Edit",
        ),
        ..moves,
      ],
    ),
  ])
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
/// input while the replica is authoritative, the connection is online and no
/// command is in flight.
fn new_task_button(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @html.button(
    type_="button",
    class="new-task",
    disabled=!mutations_allowed(model) || model.editor is Some(_),
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
        "Saving task change; waiting for authoritative confirmation."
      } else if !replica.has_snapshot() {
        "Waiting for authoritative Board state"
      } else {
        model.last_status
      },
    ),
    notice_region(model.notice),
    editor_panel(model, emit),
    @html.div(empty),
    @html.div(class="lanes", lanes().map(stage => lane(model, stage, emit))),
  ])
}
