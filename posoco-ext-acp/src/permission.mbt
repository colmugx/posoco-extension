///|
/// Permission translation (pure): ext-permission's approval vocabulary in,
/// ACP `session/request_permission` payloads and verdicts out. Which tools
/// ask, session caching, and modes are ext-permission's `PermissionPolicy`;
/// this file only speaks ACP.

///|
/// Stable permission option ids used by the built-in request builder. The
/// ids are echoed back by the client in `SelectedPermissionOutcome.option_id`
/// and are the only coupling between `acp_permission_request` and
/// `acp_decision_from_approval`.
pub const ACP_ALLOW_ONCE = "allow-once"

///|
pub const ACP_ALLOW_ALWAYS = "allow-always"

///|
pub const ACP_REJECT_ONCE = "reject-once"

///|
pub const ACP_REJECT_ALWAYS = "reject-always"

///|
/// Build the `session/request_permission` payload for one approval ask.
///
/// The carried `ToolCallUpdate` mirrors the pending announcement the client
/// has already seen (`ToolCallPending` projection): same call id, kind, and
/// title, plus the full parsed arguments as `raw_input` so the client can
/// render an informed decision UI.
pub fn acp_permission_request(
  session_id : String,
  request : @permission.ApprovalRequest,
) -> @acp.RequestPermissionRequest {
  {
    session_id,
    tool_call: {
      tool_call_id: request.call_id,
      kind: Value(acp_tool_kind(request.tool_name)),
      status: Value(Pending),
      title: Value(acp_title(request.tool_name, request.arguments)),
      content: Omitted,
      locations: Omitted,
      raw_input: Value(request.arguments),
      raw_output: Omitted,
      meta: Omitted,
    },
    options: [
      {
        option_id: ACP_ALLOW_ONCE,
        name: "Allow",
        kind: AllowOnce,
        meta: Omitted,
      },
      {
        option_id: ACP_ALLOW_ALWAYS,
        name: "Always allow",
        kind: AllowAlways,
        meta: Omitted,
      },
      {
        option_id: ACP_REJECT_ONCE,
        name: "Deny",
        kind: RejectOnce,
        meta: Omitted,
      },
      {
        option_id: ACP_REJECT_ALWAYS,
        name: "Always deny",
        kind: RejectAlways,
        meta: Omitted,
      },
    ],
    meta: Omitted,
  }
}

///|
/// Map a client permission response onto an approval decision.
///
/// `allow-always` maps to `AllowAlways`; the composed `PermissionPolicy`
/// then remembers the approval for the rest of the agent lifetime per its
/// call-shape cache (write-class keyed by (tool, path); shell and unknown
/// tools never cache). Both reject options and a cancelled request deny
/// the call — denial is terminal for the turn, so the model does not retry
/// within it.
pub fn acp_decision_from_approval(
  response : @acp.RequestPermissionResponse,
  request : @permission.ApprovalRequest,
) -> @permission.ApprovalDecision {
  let tool = @devkit.sanitize_label(request.tool_name)
  match response.outcome {
    Selected(outcome) =>
      if outcome.option_id == ACP_ALLOW_ONCE {
        @permission.ApprovalDecision::AllowOnce
      } else if outcome.option_id == ACP_ALLOW_ALWAYS {
        @permission.ApprovalDecision::AllowAlways
      } else if outcome.option_id == ACP_REJECT_ONCE {
        @permission.ApprovalDecision::Deny(
          reason="acp: client denied tool '\{tool}' (option reject-once)",
        )
      } else if outcome.option_id == ACP_REJECT_ALWAYS {
        @permission.ApprovalDecision::Deny(
          reason="acp: client denied tool '\{tool}' (option reject-always)",
        )
      } else {
        @permission.ApprovalDecision::Deny(
          reason="acp: unknown permission option '\{@devkit.sanitize_label(outcome.option_id)}' for tool '\{tool}'",
        )
      }
    Cancelled =>
      @permission.ApprovalDecision::Deny(
        reason="acp: permission request for tool '\{tool}' was cancelled by the client",
      )
  }
}
