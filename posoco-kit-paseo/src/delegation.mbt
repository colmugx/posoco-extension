// delegation.mbt — the paseo realization of the neutral delegation seam:
// intent in, Paseo orchestration tool calls out, and `get_agent_status`
// results decoded onto the neutral phase. Paseo has no official contract
// repository: every argument key name and status literal below is a local
// proposal — awaiting on-wire verification at the cetas-acp dispatch point.

///|
/// Map an intent onto `create_agent`: the `task` is mandatory, and the
/// optional `cwd` / `model` / `prompt` are forwarded when present. Key
/// names local proposal — awaiting on-wire verification.
pub fn paseo_create_call(
  intent : @delegation.DelegationIntent,
) -> @delegation.DelegationCall {
  let pairs : Array[(String, Json)] = [("task", Json::string(intent.task))]
  match intent.cwd {
    Some(dir) => pairs.push(("cwd", Json::string(dir)))
    None => ()
  }
  match intent.model {
    Some(model) => pairs.push(("model", Json::string(model)))
    None => ()
  }
  match intent.prompt {
    Some(prompt) => pairs.push(("prompt", Json::string(prompt)))
    None => ()
  }
  @delegation.DelegationCall::{
    tool: PASEO_TOOL_CREATE_AGENT,
    arguments: Json::object(Map::from_array(pairs)),
  }
}

///|
/// Map one instruction onto `send_agent_prompt` for the child agent created
/// from the corresponding `create_agent` call. Key names local proposal —
/// awaiting on-wire verification.
pub fn paseo_prompt_call(
  agent_id~ : String,
  prompt~ : String,
) -> @delegation.DelegationCall {
  @delegation.DelegationCall::{
    tool: PASEO_TOOL_SEND_AGENT_PROMPT,
    arguments: Json::object(
      Map::from_array([
        ("agentId", Json::string(agent_id)),
        ("prompt", Json::string(prompt)),
      ]),
    ),
  }
}

///|
/// Decode a `get_agent_status` result onto the neutral phase. Result shape
/// local proposal: `{ "agentId": ..., "status": ... }` with the status
/// literals `queued` / `running` / `completed` / `failed` / `cancelled` /
/// `killed` (both stops are terminal failures). Unknown literals are errors,
/// not guesses — awaiting on-wire verification.
pub fn parse_agent_phase(
  raw : Json,
) -> Result[@delegation.DelegationPhase, String] {
  guard raw is Json::Object(fields) else {
    return Err("paseo: agent status must be a JSON object")
  }
  let status = match fields.get("status") {
    Some(Json::String(status)) => status
    Some(_) =>
      return Err("paseo: agent status field \"status\" must be a string")
    None =>
      return Err("paseo: agent status is missing required field \"status\"")
  }
  match status {
    "queued" => Ok(@delegation.DelegationPhase::Queued)
    "running" => Ok(@delegation.DelegationPhase::Running)
    "completed" => Ok(@delegation.DelegationPhase::Succeeded)
    "failed" => Ok(@delegation.DelegationPhase::Failed)
    "cancelled" => Ok(@delegation.DelegationPhase::Failed)
    "killed" => Ok(@delegation.DelegationPhase::Failed)
    other => Err("paseo: unknown agent status literal \"\{other}\"")
  }
}
