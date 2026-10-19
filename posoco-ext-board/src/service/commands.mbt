///|
let workflow_actions : Array[(String, String)] = [
  ("status", "Inspect authoritative status"),
  ("start", "Start bounded workflow"),
  ("propose", "Request Agent DAG proposal"),
  ("preview", "Preview proposed DAG"),
  ("graph.approve", "Approve graph commit only"),
  ("graph.reject", "Reject graph proposal"),
  ("scope.approve", "Approve execution scope separately"),
  ("scope.reject", "Deny execution scope"),
  ("prepare", "Prepare task with trusted input"),
  ("run", "Run next eligible wave"),
  ("wait", "Wait for settled wave"),
  ("pause", "Pause admission"),
  ("resume", "Resume without dispatch"),
  ("stop", "Stop after current wave"),
  ("cancel", "Cancel actual workflow executions"),
  ("move", "Operator-controlled Task transition"),
  ("reconcile", "Read-only reconciliation"),
]

///|
pub impl @posoco.CommandPort for BoardWorkflows with fn commands(_) {
  let definitions = workflow_actions.map(action => @posoco.CommandDef::{
    id: "board.workflow." + action.0,
    label: action.1,
    description: action.1,
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: true,
    metadata: None,
  })
  definitions.push(@posoco.CommandDef::{
    id: "board.workflow",
    label: "Board workflow",
    description: "Control a bounded Board workflow; graph and execution approvals are separate",
    category: "board",
    ctype: @posoco.CommandType::Action,
    params: [],
    aliases: ["workflow"],
    shortcut: None,
    icon: None,
    visible: true,
    metadata: None,
  })
  definitions
}

///|
async fn BoardWorkflows::input(
  self : BoardWorkflows,
  prompt : String,
) -> String {
  let ui = match self.ui {
    Some(ui) => ui
    None => raise WorkflowFault(MissingUi)
  }
  match ui.request(@posoco.UiRequest::Input(prompt~, default=None)) {
    @posoco.UiResponse::Text(text) => text
    _ => raise WorkflowFault(ApprovalDenied)
  }
}

///|
async fn BoardWorkflows::choose(
  self : BoardWorkflows,
  prompt : String,
  options : Array[String],
) -> String {
  if options.is_empty() {
    raise WorkflowFault(OperationRejected)
  }
  let ui = match self.ui {
    Some(ui) => ui
    None => raise WorkflowFault(MissingUi)
  }
  match
    ui.request(
      @posoco.UiRequest::Select(prompt~, options=options.copy(), default=None),
    ) {
    @posoco.UiResponse::Selected(index) =>
      match options.get(index) {
        Some(option) => option
        None => raise WorkflowFault(ApprovalDenied)
      }
    _ => raise WorkflowFault(ApprovalDenied)
  }
}

///|
fn success(value : Json) -> @posoco.CommandOutcome {
  @posoco.CommandOutcome::Success(
    feedback=value.stringify(indent=2),
    structured=Some(value),
    ui_hint=Some(@posoco.UiHint::None),
  )
}

///|
fn outcome(
  value : Result[BoardWorkflowView, BoardWorkflowError],
) -> @posoco.CommandOutcome {
  match value {
    Ok(view) => success(view.to_json())
    Err(error) => @posoco.CommandOutcome::Failure(reason=error.code())
  }
}

///|
pub impl @posoco.CommandPort for BoardWorkflows with fn invoke(self, id, args) {
  if self.closed {
    return @posoco.CommandOutcome::Failure(reason="Board workflow is closed")
  }
  if !(args is Object(fields) && fields.is_empty()) {
    return @posoco.CommandOutcome::Failure(
      reason="Board commands accept trusted UI decisions, not executable JSON arguments",
    )
  }
  try {
    let selected = if id == "board.workflow" || id == "workflow" {
      let label = self.choose(
        "Board workflow — select an explicit operation",
        workflow_actions.map(a => a.1),
      )
      "board.workflow." +
      workflow_actions.iter().find_first(a => a.1 == label).unwrap().0
    } else {
      id
    }
    match selected {
      "board.workflow.start" =>
        outcome(
          self.start(
            title=self.input("Workflow title (no credentials or raw prompt)"),
          ),
        )
      "board.workflow.status" => outcome(self.view())
      "board.workflow.propose" => {
        let parent = self.choose(
          "Authorize one planning run for this parent",
          self.running().status().scope,
        )
        let requirements = self.input(
          "Trusted planning requirements; no private Board context is implicitly included",
        )
        match self.propose(parent~, requirements~) {
          Ok(preview) => success(preview)
          Err(error) => @posoco.CommandOutcome::Failure(reason=error.code())
        }
      }
      "board.workflow.preview" =>
        match self.preview_ {
          Some(preview) => success(graph_preview_json(preview))
          None =>
            @posoco.CommandOutcome::Failure(
              reason="No decoded proposal awaiting graph approval",
            )
        }
      "board.workflow.graph.approve" => outcome(self.graph_decision(grant=true))
      "board.workflow.graph.reject" => outcome(self.graph_decision(grant=false))
      "board.workflow.scope.approve" | "board.workflow.scope.reject" => {
        let view = self.read_view()
        let id = self.choose(
          "Committed expansion — canonical IDs remain unchanged",
          view.snapshot.expansions
          .filter(e => e.workflow_id == self.workflow.val)
          .map(e => e.expansion_id.value),
        )
        outcome(
          self.scope_decision(
            expansion_id=id,
            grant=selected == "board.workflow.scope.approve",
          ),
        )
      }
      "board.workflow.prepare" => {
        let task_id = self.choose(
          "Authorized generated Task to prepare",
          self.running().status().scope,
        )
        let input = self.input(
          "Trusted execution input for this Task; its generated description does not authorize tools",
        )
        outcome(self.prepare(task_id~, input~))
      }
      "board.workflow.run" => outcome(self.run_wave())
      "board.workflow.wait" => outcome(self.wait_boundary())
      "board.workflow.pause" =>
        success({ "pause_requested": Json::boolean(self.pause()) })
      "board.workflow.resume" => outcome(self.resume_workflow())
      "board.workflow.stop" => {
        self.stop_after_wave()
        success({ "stop_after_wave_requested": true })
      }
      "board.workflow.cancel" => {
        self.cancel()
        success({ "cancel_requested": true, "settled": false })
      }
      "board.workflow.move" => {
        let task_id = self.choose(
          "Task to move after verifying evidence",
          self.running().status().scope,
        )
        let name = self.choose(
          "Legal Task transition only; never automatic Review approval",
          ["Refining", "Ready", "Running", "Review", "Done", "Suspended"],
        )
        let stage = match name {
          "Refining" => @domain.Refining
          "Ready" => @domain.Ready
          "Running" => @domain.Running
          "Review" => @domain.Review
          "Done" => @domain.Done
          _ => @domain.Suspended
        }
        let evidence = self.input(
          "Confirm the evidence you independently verified",
        )
        outcome(self.move_task(task_id~, stage~, evidence~))
      }
      "board.workflow.reconcile" => {
        let options = [
          "Graph proposal",
          ..self.running().status().partial_preparations.map(p => p.task_id),
        ]
        let selected = self.choose(
          "Read-only evidence check; no retry or replay", options,
        )
        if selected == "Graph proposal" {
          outcome(self.reconcile())
        } else {
          outcome(self.reconcile(task_id=selected))
        }
      }
      _ =>
        @posoco.CommandOutcome::Failure(reason="Unknown Board workflow command")
    }
  } catch {
    error => @posoco.CommandOutcome::Failure(reason=safe_error(error).code())
  }
}
