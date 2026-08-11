# posoco-ext-continuity

Session Continuity for Posoco/Cetas.

The extension keeps the active transcript bounded while preserving older session history as recoverable checkpoints. Its product model is:

- **Working set** — recent canonical messages kept directly in model context.
- **Checkpoint** — structured compact state for settled historical work.
- **Archive** — original canonical messages retained as historical evidence.
- **Recall** — search/read of archived history when exact details matter.

A checkpoint is intentionally not described as lossless. Exact facts should be recovered from the archive.

## Architecture

`posoco-ext-continuity` is composed entirely from existing Posoco ports. It does not require Continuity-specific changes in Posoco.

One `ContinuityExtension` instance is exposed through several port views so they share the same state:

- **ModelPort decorator** — receives Posoco's existing `InvocationScope` and records the canonical current session/run before delegating to the configured model.
- **Hook** — owns transcript planning and rewrite behavior. `before_model` is the place where prepared checkpoints replace older settled transcript ranges.
- **Observer** — owns turn-level lifecycle bookkeeping (`TurnStarted`, `TurnCompleted`, `TurnFailed`, redirects, telemetry).
- **SystemPromptContributor** — teaches the model the checkpoint/recall protocol.
- **ToolProvider** — will expose checkpoint/search/read/status once the prepare/commit path is wired.

The important separation is:

- Hook changes execution state.
- Observer watches committed turn-level outcomes.
- ModelPort provides the invocation identity that Posoco already defines.
- The model never chooses a session id.

## v0.1 status

This branch currently contains:

- Posoco 0.10.1 alignment;
- context-budget classification;
- provider-neutral token-size estimation;
- conservative working-set planning;
- structured checkpoint summaries;
- checkpoint rendering;
- in-memory per-session archive;
- lexical history search and paginated read;
- static `SystemPromptContributor` protocol;
- scope-aware `ContinuityExtension` model decorator;
- Hook + Observer registration on the same extension instance;
- core tests.

The remaining runtime work is:

1. bind planner candidates to the `InvocationScope` observed by the model decorator;
2. implement `session_checkpoint` prepare semantics;
3. apply prepared checkpoints from `Hook::before_model` as canonical transcript rewrites;
4. expose `session_history_search`, `session_history_read`, and `session_continuity_status`;
5. add durable archive storage and end-to-end tests.

## Composition

Continuity wraps the model that would otherwise be registered directly:

```moonbit
let continuity = continuity_extension(model as &@posoco.ModelPort)

let agent = @posoco.Agent(
  exts=[
    continuity as &@posoco.Extension,
    // session store and other tool extensions...
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
5. Hook and Observer responsibilities remain separate: interception in Hook, lifecycle/telemetry in Observer.

## License

Apache-2.0
