# posoco-ext-continuity

Session Continuity for Posoco/Cetas.

The extension keeps long-running sessions workable by folding settled historical work into compact checkpoints while preserving the original canonical messages in a recoverable archive.

Its model is:

- **Working set** — recent canonical messages kept directly in model context.
- **Checkpoint** — structured compact state for settled historical work.
- **Archive** — original canonical messages retained as historical evidence.
- **Recall** — search/read of archived history when exact details matter.

A checkpoint is intentionally not described as lossless. Exact historical facts come from the archive.

## Architecture

`posoco-ext-continuity` is composed from existing Posoco 0.10.1 ports and does not require Continuity-specific changes in Posoco.

One `ContinuityExtension` instance is exposed through several port views so they share the same state:

- **ModelPort decorator** — receives Posoco's canonical `InvocationScope`, plans system-selected checkpoint candidates, presents candidate notices ephemerally to the inner model, and delegates the real model call.
- **Hook** — applies a prepared checkpoint as a canonical transcript rewrite at `before_model`. It rewrites only when the archived source range still matches exactly.
- **ToolProvider** — exposes checkpoint, history search/read, and status tools.
- **Observer** — owns turn-level lifecycle cleanup. It does not infer or supply session identity.
- **SystemPromptContributor** — teaches the model the checkpoint/recall protocol.

The separation is deliberate:

- ModelPort owns invocation identity and ephemeral candidate presentation.
- Hook owns canonical transcript mutation.
- ToolProvider owns explicit continuity operations.
- Observer watches turn-level lifecycle.
- The model never supplies a session id or chooses the historical message range to fold.

## Tools

### `session_checkpoint`

Accepts an opaque system-generated `candidate_id` plus a structured summary of settled work. The extension archives the exact source messages first, then marks the checkpoint prepared. The next matching `before_model` boundary performs the canonical rewrite.

### `session_history_search`

Searches only the current session's archived messages using lexical exact-substring matching in v0.1. Results are bounded and return opaque history references plus previews.

### `session_history_read`

Reads one bounded page from an archived history reference. Pagination prevents recall itself from flooding the active context.

### `session_continuity_status`

Reports the current session's committed checkpoint count, archived message count, and whether a candidate or prepared checkpoint is pending.

## Checkpoint lifecycle

```text
model call
  ↓
planner selects old stable prefix
  ↓
ephemeral candidate notice
  ↓
session_checkpoint
  ↓
archive exact canonical messages
  ↓
PreparedCheckpoint
  ↓
next Hook::before_model
  ↓
verify identity + exact source range
  ↓
canonical raw prefix → checkpoint SystemMessage
```

If the source range no longer matches, the Hook leaves the canonical transcript unchanged. The previously archived copy may remain, but Continuity never removes canonical history on a stale candidate.

## v0.1 implementation status

Implemented on this branch:

- Posoco 0.10.1 alignment;
- context-budget classification;
- provider-neutral token-size estimation;
- conservative working-set planning;
- system-selected runtime checkpoint candidates;
- structured checkpoint summaries and rendering;
- archive-before-fold ordering;
- exact-range validation before canonical rewrite;
- in-memory per-session archive;
- lexical history search;
- paginated history read;
- `session_checkpoint`;
- `session_history_search`;
- `session_history_read`;
- `session_continuity_status`;
- scope-aware `ContinuityExtension` ModelPort decorator;
- Hook + Observer + ToolProvider + SystemPromptContributor composition;
- whitebox tests and a scripted Agent checkpoint/archive/rewrite test path.

Still required before calling v0.1 production-ready:

1. run `moon check`, `moon test`, `moon fmt`, and `moon info` in a MoonBit toolchain;
2. fix any compiler/API issues exposed by that pass;
3. replace or abstract the current in-memory archive with durable storage;
4. add crash/restart recovery tests around archive-before-fold semantics;
5. add stronger session-isolation and stale-candidate tests;
6. tune budget defaults against real Cetas sessions.

`ContinuityConfig.context_window` should be configured consistently with the model context window used by the host. It is currently explicit plugin configuration rather than inferred from Posoco Agent configuration.

## Composition

Continuity wraps the model that would otherwise be registered directly:

```moonbit
let continuity = continuity_extension(model as &@posoco.ModelPort)

let agent = @posoco.Agent(
  exts=[
    continuity as &@posoco.Extension,
    // session store and other extensions...
  ],
  config=...,
)
```

Only the wrapped Continuity model should be contributed to the final Agent model slot.

## Safety invariants

1. Current intent stays active.
2. History is archived before it is folded out of the canonical transcript.
3. Checkpoints are working hints; archives are historical evidence.
4. Session identity comes from Posoco's canonical invocation scope, never from model arguments.
5. A stale or changed source range is never removed from the canonical transcript.
6. Hook and Observer responsibilities remain separate: interception in Hook, lifecycle observation in Observer.

## License

Apache-2.0
