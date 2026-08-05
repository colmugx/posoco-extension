///|
/// The plan-mode tool pair:
///
/// - `enter_plan_mode`: the model asks to enter plan mode on its own. Entry
///   never needs user approval — plan mode is a safe read-only state; only
///   exiting does. Only advertised when `config.allow_model_entry` is true.
/// - `exit_plan_mode`: the model's signal that a plan is ready for user
///   approval. Calling it does NOT exit plan mode; only the product-side
///   `plan.approve` command exits.
///
/// Both are always allowed by the Hook gate.

///|
fn exit_tool_def(config : PlanModeConfig) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(config.exit_tool_name),
    description: "Submit a completed implementation plan for user approval. Call this only while in plan mode, once the plan is concrete and step-by-step.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "plan": Json::object({
          "type": Json::string("string"),
          "description": "The full step-by-step plan to be reviewed by the user",
        }),
      }),
      "required": Json::array([Json::string("plan")]),
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
    description: "Enter plan mode: switch to read-only investigation and produce a step-by-step plan before making any changes. Use for non-trivial tasks that modify the system.",
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
        content="Plan mode is now active. Investigate with read-only tools, then call '\{self.config.exit_tool_name}' with the completed plan. Write tools are disabled until the user approves the plan.",
        structured=None,
      )
    }
    Planning =>
      @posoco.ToolOutcome::Success(
        content="Already in plan mode. Continue investigating read-only, then call '\{self.config.exit_tool_name}' when the plan is ready.",
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
/// Execute the exit tool: record the plan and move to `ReadyForApproval`.
/// The returned message tells the model to stop and wait — exiting itself
/// only happens when the product approves (`plan.approve` command).
fn PlanMode::execute_exit(
  self : PlanMode,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let plan = match call.arguments {
    Object(obj) =>
      match obj.get("plan") {
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
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "\{name}: arguments must be a JSON object",
      )
  }
  if !self.submit_plan(plan) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="\{name}: not in plan mode. Enable plan mode before submitting a plan.",
      structured=None,
    )
  }
  @posoco.ToolOutcome::Success(
    content="Plan submitted for user approval. Do not make any changes until the user approves the plan.",
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
