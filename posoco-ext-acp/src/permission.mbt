///|
/// Permission request construction and response mapping (pure).

///|
/// Stable permission option ids used by the built-in request builder. The
/// ids are echoed back by the client in `SelectedPermissionOutcome.option_id`
/// and are the only coupling between `acp_permission_request` and
/// `acp_decision_from_response`.
pub const ACP_ALLOW_ONCE = "allow-once"

///|
pub const ACP_ALLOW_ALWAYS = "allow-always"

///|
pub const ACP_REJECT_ONCE = "reject-once"

///|
pub const ACP_REJECT_ALWAYS = "reject-always"

///|
/// Build the `session/request_permission` payload for one Posoco tool call.
///
/// The carried `ToolCallUpdate` mirrors the pending announcement the client
/// has already seen (`ToolCallPending` projection): same call id, kind, and
/// title, plus the raw parsed arguments as `raw_input` so the client can
/// render an informed decision UI.
pub fn acp_permission_request(
  session_id : String,
  call : @posoco.ToolCall,
) -> @acp.RequestPermissionRequest {
  {
    session_id,
    tool_call: {
      tool_call_id: call.call_id.to_string(),
      kind: Value(acp_tool_kind(call.name.to_string())),
      status: Value(Pending),
      title: Value(acp_tool_title(call)),
      content: Omitted,
      locations: Omitted,
      raw_input: Value(call.arguments),
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
/// Map a client permission response onto a Posoco hook decision.
///
/// Both allow options approve the call unchanged; any reject option and a
/// cancelled request reject it (the run then fails loudly with the reason,
/// which the model-side transcript and the ACP prompt response both carry).
pub fn acp_decision_from_response(
  response : @acp.RequestPermissionResponse,
  call : @posoco.ToolCall,
) -> @posoco.ToolHookDecision {
  let tool = @devkit.sanitize_label(call.name.to_string())
  match response.outcome {
    Selected(outcome) =>
      if outcome.option_id == ACP_ALLOW_ONCE ||
        outcome.option_id == ACP_ALLOW_ALWAYS {
        @posoco.ToolHookDecision::Approve(call~)
      } else {
        @posoco.ToolHookDecision::Reject(
          reason="acp: client denied tool '\{tool}' (option \{outcome.option_id})",
        )
      }
    Cancelled =>
      @posoco.ToolHookDecision::Reject(
        reason="acp: permission request for tool '\{tool}' was cancelled by the client",
      )
  }
}
