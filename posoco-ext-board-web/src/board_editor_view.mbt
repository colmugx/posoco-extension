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

