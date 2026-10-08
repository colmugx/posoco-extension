///|
fn task_card(
  replica : @client.BoardReplica,
  task : @client.ClientBoardTask,
) -> @html.Html {
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
  ])
}

///|
fn lane(
  replica : @client.BoardReplica,
  stage : @client.ClientBoardStage,
) -> @html.Html {
  let tasks = tasks_in_lane(replica, stage)
  @html.section(class="lane", [
    @html.h2("\{stage_label(stage)} · \{tasks.length()}"),
    @html.div(class="cards", tasks.map(task => task_card(replica, task))),
  ])
}

///|
fn view(model : Model) -> @html.Html {
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
    ]),
    @html.p(
      class="status",
      attrs=@html.Attrs::build().role("status").aria_live("polite"),
      model.last_status,
    ),
    @html.div(empty),
    @html.div(class="lanes", lanes().map(stage => lane(replica, stage))),
  ])
}
