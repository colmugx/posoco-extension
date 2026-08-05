///|
/// Plan mode commands: `/plan on|off|status`, `/plan.approve`,
/// `/plan.reject`. Slash and panel consumers use these to drive the state
/// machine; approval stays an explicit user action on the product side.

///|
/// Machine-readable status for panel consumers.
fn PlanMode::status_json(self : PlanMode) -> Json {
  let (status, plan) = match self.status {
    Off => ("off", Json::null())
    Planning => ("planning", Json::null())
    ReadyForApproval(plan~) => ("ready_for_approval", Json::string(plan))
  }
  Json::object({
    "status": Json::string(status),
    "plan": plan,
    "allowed_tools": Json::array(self.config.allowed_tools.map(Json::string)),
  })
}

///|
/// Parse an optional non-empty string argument.
fn parse_optional_string(
  fields : Map[String, Json],
  key : String,
) -> String? raise @posoco.CommandError {
  match fields.get(key) {
    None => None
    Some(String(value)) => if value.length() == 0 { None } else { Some(value) }
    Some(_) =>
      raise @posoco.CommandError::InvalidArgs(
        reason="plan command: '\{key}' must be a string",
      )
  }
}

///|
/// Extract an optional positional argument (string or {action} object).
fn parse_action(args : Json) -> String? raise @posoco.CommandError {
  match args {
    Json::Null => None
    String(action) => if action.length() == 0 { None } else { Some(action) }
    Object(fields) => parse_optional_string(fields, "action")
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/plan expects no arguments, an action string, or {action}",
      )
  }
}

///|
fn str_param(
  name : String,
  label : String,
  description : String,
  required : Bool,
  positional : Bool,
  choices : Array[String]?,
) -> @posoco.CommandParam {
  @posoco.CommandParam::{
    name,
    label,
    description,
    ptype: @posoco.ParamType::Str,
    required,
    default: None,
    choices,
    positional,
  }
}

///|
pub impl @posoco.CommandPort for PlanMode with fn commands(self) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "plan",
      label: "Plan Mode",
      description: "Enter, leave, or inspect plan mode",
      category: "plan",
      ctype: @posoco.CommandType::Toggle,
      params: [
        str_param(
          "action",
          "Action",
          "on / off / status (default: toggle)",
          false,
          true,
          Some(["on", "off", "status"]),
        ),
      ],
      aliases: [],
      shortcut: Some("shift+tab"),
      icon: None,
      visible: true,
      metadata: None,
    },
    @posoco.CommandDef::{
      id: "plan.approve",
      label: "Approve Plan",
      description: "Approve the submitted plan and leave plan mode",
      category: "plan",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    @posoco.CommandDef::{
      id: "plan.reject",
      label: "Reject Plan",
      description: "Reject the submitted plan and keep planning",
      category: "plan",
      ctype: @posoco.CommandType::Action,
      params: [
        str_param(
          "feedback",
          "Feedback",
          "Why the plan was rejected, fed back to the model",
          false,
          true,
          None,
        ),
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
pub impl @posoco.CommandPort for PlanMode with fn invoke(
  self,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "plan" =>
      match parse_action(args) {
        None => {
          // Bare /plan toggles, like Shift+Tab in kimi-code.
          self.toggle()
          let feedback = match self.status() {
            PlanStatus::Off => "plan mode off"
            _ =>
              "plan mode on — write tools are disabled until a plan is approved"
          }
          @posoco.CommandOutcome::Success(
            feedback~,
            structured=Some(self.status_json()),
            ui_hint=Some(@posoco.UiHint::Toast),
          )
        }
        Some("on") => {
          self.start()
          @posoco.CommandOutcome::Success(
            feedback="plan mode on — write tools are disabled until a plan is approved",
            structured=Some(self.status_json()),
            ui_hint=Some(@posoco.UiHint::Toast),
          )
        }
        Some("off") => {
          self.stop()
          @posoco.CommandOutcome::Success(
            feedback="plan mode off",
            structured=Some(self.status_json()),
            ui_hint=Some(@posoco.UiHint::Toast),
          )
        }
        Some("status") =>
          @posoco.CommandOutcome::Success(
            feedback="plan mode status: \{self.status}",
            structured=Some(self.status_json()),
            ui_hint=None,
          )
        Some(other) =>
          @posoco.CommandOutcome::Failure(
            reason="unknown plan action '\{other}' (expected on/off/status)",
          )
      }
    "plan.approve" =>
      match self.approve() {
        Some(_) =>
          @posoco.CommandOutcome::Success(
            feedback="plan approved — plan mode off, execution may proceed",
            structured=Some(self.status_json()),
            ui_hint=Some(@posoco.UiHint::Toast),
          )
        None =>
          @posoco.CommandOutcome::Failure(
            reason="no plan is waiting for approval",
          )
      }
    "plan.reject" => {
      let feedback = match args {
        Object(fields) => parse_optional_string(fields, "feedback")
        String(value) => Some(value)
        _ => None
      }
      if self.reject() {
        let suffix = match feedback {
          Some(text) => " — feedback: \{text}"
          None => ""
        }
        @posoco.CommandOutcome::Success(
          feedback="plan rejected, still planning\{suffix}",
          structured=Some(self.status_json()),
          ui_hint=Some(@posoco.UiHint::Toast),
        )
      } else {
        @posoco.CommandOutcome::Failure(
          reason="no plan is waiting for approval",
        )
      }
    }
    other => raise @posoco.CommandError::NotFound(other)
  }
}
