// delegation.mbt — the provider-neutral delegation seam shared by the host
// kits: one caller-side intent, one concrete MCP tool invocation, one
// unified phase view for dispatchers.
// Host kits map the intent onto their own tool vocabularies and translate
// their contract-specific status tracks onto `DelegationPhase`; nothing in
// this file mentions a specific host.

///|
/// Caller-side delegation intent, provider-neutral. `task` is the one-line
/// goal surfaced to orchestrators; `cwd` optionally places the delegated
/// work; `model` optionally pins the child's model; `prompt` is the full
/// instruction handed to the delegated session when it differs from the
/// one-line goal.
pub(all) struct DelegationIntent {
  task : String
  cwd : String?
  model : String?
  prompt : String?
} derive(Eq, Debug)

///|
pub extend DelegationIntent with Eq::{not_equal, equal}

///|
pub extend DelegationIntent with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One concrete MCP tool invocation against the delegated-work host.
pub(all) struct DelegationCall {
  tool : String
  arguments : Json
} derive(Eq, Debug)

///|
pub extend DelegationCall with Eq::{not_equal, equal}

///|
pub extend DelegationCall with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Unified delegation phase for dispatchers: every host kit decodes its own
/// (deliberately disjoint) status vocabularies onto this single view.
pub(all) enum DelegationPhase {
  Queued
  Running
  Succeeded
  Failed
  Lost
} derive(Eq, Debug)

///|
pub extend DelegationPhase with Eq::{not_equal, equal}

///|
pub extend DelegationPhase with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Materialize the call as a posoco tool call; the caller owns the call id.
pub fn DelegationCall::to_tool_call(
  self : DelegationCall,
  call_id~ : String,
) -> Result[@posoco.ToolCall, String] {
  match @posoco.CallId::checked(call_id) {
    Err(message) => Err("invalid call id: \{message}")
    Ok(id) =>
      match @posoco.ToolName::checked(self.tool) {
        Err(message) => Err("invalid tool name: \{message}")
        Ok(name) =>
          Ok(@posoco.ToolCall::{ call_id: id, name, arguments: self.arguments, })
      }
  }
}
