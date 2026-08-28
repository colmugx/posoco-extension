///|
/// The plan-mode tool pair:
///
/// - `enter_plan_mode`: the model asks to enter plan mode on its own. Entry
///   never needs user approval — plan mode is a safe research state; only
///   exiting does. Only advertised when `config.allow_model_entry` is true.
/// - `exit_plan_mode`: the model's signal that a plan is ready for user
///   approval. With a review source wired, the review runs on this call:
///   `Accept` approves and exits in one action, `Revise(feedback)` keeps
///   planning, `Dismiss` cancels and stops the turn (best-effort). Without
///   one, the plan is recorded as `ReadyForApproval` and only the
///   product-side `plan.approve` command exits.
///
/// Both are always allowed by the Hook gate.

///|
fn exit_tool_def(config : PlanModeConfig) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(config.exit_tool_name),
    description: "Submit a completed implementation plan for user approval. Give the plan a short `name`; call this only while in plan mode, once the plan is concrete and step-by-step.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "name": Json::object({
          "type": Json::string("string"),
          "description": "A short name for this plan, chosen by you; it names the saved plan file",
        }),
        "plan": Json::object({
          "type": Json::string("string"),
          "description": "The full step-by-step plan to be reviewed by the user",
        }),
      }),
      "required": Json::array([Json::string("name"), Json::string("plan")]),
    }),
    owner: @posoco.OwnerId::unchecked("posoco_ext_plan"),
    policy: @posoco.ExecutionPolicy::Sequential,
    provenance: Some("posoco_ext_plan"),
  }
}

///|
fn enter_tool_def(config : PlanModeConfig) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(config.enter_tool_name),
    description: "Enter plan mode: switch to read-only investigation and produce a step-by-step plan before making any changes. Use for non-trivial tasks that modify the system. While planning you may write Markdown files anywhere in the workspace; every other change belongs in the plan.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({}),
    }),
    owner: @posoco.OwnerId::unchecked("posoco_ext_plan"),
    policy: @posoco.ExecutionPolicy::Sequential,
    provenance: Some("posoco_ext_plan"),
  }
}

///|
/// Declare the plan-mode tools. The enter tool is advertised only when
/// model-initiated entry is enabled. Owner/policy placeholders follow the
/// ToolProvider contract — the catalog builder overwrites them.
pub impl @posoco.ToolProvider for PlanMode with fn list_tools(self) -> Array[
  @posoco.ToolDef,
] {
  let tools : Array[@posoco.ToolDef] = [exit_tool_def(self.config)]
  if self.config.allow_model_entry {
    tools.push(enter_tool_def(self.config))
  }
  tools
}

///|
/// Execute the enter tool: Off → Planning. Idempotent while planning —
/// re-entering just confirms the current state.
fn PlanMode::execute_enter(
  self : PlanMode,
  name : String,
) -> @posoco.ToolOutcome {
  match self.status {
    Off => {
      self.start()
      @posoco.ToolOutcome::Success(
        content="Plan mode is now active. Investigate freely — every conclusion must be accurate and traceable — then call '\{self.config.exit_tool_name}' with the completed plan. You may write Markdown (.md) files anywhere in the workspace for notes and drafts; all other changes must go into the plan.",
        structured=None,
      )
    }
    Planning =>
      @posoco.ToolOutcome::Success(
        content="Already in plan mode. Continue investigating, then call '\{self.config.exit_tool_name}' when the plan is ready.",
        structured=None,
      )
    ReadyForApproval(..) =>
      @posoco.ToolOutcome::ToolReportedError(
        content="\{name}: a plan is already waiting for user approval.",
        structured=None,
      )
  }
}

///|
/// Review-wired: ask the review source on this very call — `Accept` approves
/// and leaves plan mode in one action, `Revise(feedback)` keeps planning
/// with the feedback as the tool result, `Dismiss` cancels and stops the
/// turn. Without a review source, record the plan as `ReadyForApproval`
/// for the command flow. Every completed path echoes the plan once.
async fn PlanMode::execute_exit(
  self : PlanMode,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (plan_name, plan) = match call.arguments {
    Object(obj) => {
      let plan = match obj.get("plan") {
        Some(String(p)) => p
        Some(_) =>
          raise @posoco.RuntimeError::InvocationFailed(
            "\{name}: 'plan' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::InvocationFailed(
            "\{name}: missing 'plan' argument",
          )
      }
      let plan_name = match obj.get("name") {
        Some(String(n)) =>
          if n.trim().length() == 0 {
            raise @posoco.RuntimeError::InvocationFailed(
              "\{name}: 'name' argument must not be empty",
            )
          } else {
            n
          }
        Some(_) =>
          raise @posoco.RuntimeError::InvocationFailed(
            "\{name}: 'name' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::InvocationFailed(
            "\{name}: missing 'name' argument — give the plan a short name",
          )
      }
      (plan_name, plan)
    }
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "\{name}: arguments must be a JSON object",
      )
  }
  if self.status is Off {
    return @posoco.ToolOutcome::ToolReportedError(
      content="\{name}: not in plan mode. Enable plan mode before submitting a plan.",
      structured=None,
    )
  }
  // The review only runs while planning; a resubmission while
  // ReadyForApproval falls through to the command flow.
  if self.status is Planning {
    match self.review {
      Some(source) => {
        let decision = source.review(PlanReviewRequest::{ plan, }) catch {
          err =>
            return @posoco.ToolOutcome::ToolReportedError(
              content="\{name}: plan review failed (\{err.to_string()}). Still in plan mode — call '\{name}' again once the review is available.",
              structured=None,
            )
        }
        return match decision {
          Accept => {
            self.status = Off
            self.publish_status()
            let saved = self.save_final_plan(plan_name, plan)
            let saved_line = match saved {
              Some(path) => "\n\nSaved to \{path}."
              None => ""
            }
            @posoco.ToolOutcome::Success(
              content="Plan accepted by the user — plan mode is off. Implement the plan now, starting with step 1:\n\n\{plan}\{saved_line}",
              structured=None,
            )
          }
          Revise(feedback~) =>
            @posoco.ToolOutcome::ToolReportedError(
              content="Plan returned for revision: \{feedback}. Stay in plan mode, incorporate the feedback, and call '\{name}' again with the revised plan.",
              structured=None,
            )
          Dismiss => {
            self.status = Off
            self.publish_status()
            @posoco.ToolOutcome::ToolReportedError(
              content="Plan dismissed by the user — the turn is cancelled. Make no further tool calls; end your reply now.",
              structured=None,
            )
          }
        }
      }
      None => ()
    }
  }
  ignore(self.submit_plan(plan))
  let saved = self.save_final_plan(plan_name, plan)
  let saved_line = match saved {
    Some(path) => "\n\nSaved to \{path}."
    None => ""
  }
  @posoco.ToolOutcome::Success(
    content="Plan submitted for user approval — do not make any changes until the user decides:\n\n\{plan}\{saved_line}",
    structured=None,
  )
}

///|
pub impl @posoco.ToolProvider for PlanMode with fn execute(
  self,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name == self.config.exit_tool_name {
    return self.execute_exit(name, call)
  }
  if name == self.config.enter_tool_name && self.config.allow_model_entry {
    return self.execute_enter(name)
  }
  raise @posoco.RuntimeError::UnknownTool(
    "posoco_ext_plan: unknown tool '\{name}'",
  )
}
