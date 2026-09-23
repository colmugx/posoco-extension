///|
/// Fully resolved spawn request handed to a `ChildComposer` (design §3.1).
/// Every slicing decision (model slot, effort, tool face, skills, system
/// prompt) has already been made by the `agent` tool; the composer only
/// assembles the child `Agent` — it must not re-derive or widen the trim.
///
/// No `Debug` derive: the `observers` field holds trait objects that cannot
/// carry a derived `Debug` impl; consumers pattern-match fields instead.
pub(all) struct ChildSpec {
  /// Task text. User-position slot: untrusted content may flow here; it is
  /// passed to the child as the turn's user message, never into the system
  /// prompt.
  task : String
  /// Kind the child was spawned with (catalog key).
  kind_name : String
  /// Child session id, minted by the tool or taken from the `resume` arg.
  session_id : String
  /// True when continuing an existing child session (composer swaps in the
  /// fs-session store). Named `resuming`: `resume` is a reserved keyword.
  resuming : Bool
  /// Spawn whitelist ∩ kind whitelist, computed by the tool (design §6.2).
  /// Depth 1 is structural: this face never contains `agent`/`agent_swarm`.
  tools : Array[String]
  /// `None` = do not load skills; `Some(list)` = whitelist; `Some([])` =
  /// load everything discovered.
  skills : Array[String]?
  /// Permission posture declared by the kind frontmatter.
  mode : @permission.PermissionMode
  /// System prompt assembled by the kit (`assemble_system_prompt`): kind
  /// template plus the trust-annotated instructions fill-in.
  system_prompt : String
  /// Model slot resolved from subagent-config (kit `resolve`).
  slot : String
  /// Reasoning effort resolved from subagent-config.
  effort : String?
  /// Whether the child inherits project context files (AGENTS.md etc.).
  context_files : Bool
  /// Observers to attach to the child Agent. The tool's `BridgeObserver`
  /// rides here so child events reach the extension's subscription channel.
  observers : Array[&@posoco.Observer]
}

///|
/// Child-composition failures. Raised by the composer when the child Agent
/// cannot be assembled; the `agent` tool maps it to the `failed` terminal
/// state, never to a silent drop.
pub(all) suberror ComposerError {
  Failed(String)
}

///|
/// Port seam: assembles the child `Agent` for one spawn (design §3.1).
/// Implemented by host glue (cetas side, Round 2) which owns the real
/// feature-set trimming and provider reuse; this extension only defines the
/// contract and injects it at construction. Tests provide fake composers
/// that build a real child Agent from testkit fakes.
pub(open) trait ChildComposer {
  async fn compose(Self, spec : ChildSpec) -> @posoco.Agent raise ComposerError
}
