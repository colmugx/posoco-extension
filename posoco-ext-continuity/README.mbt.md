# posoco-ext-continuity

Session Continuity for Posoco/Cetas.

The extension keeps the active transcript bounded while preserving older session history as recoverable checkpoints. Its product model is:

- **Working set** — recent canonical messages kept directly in model context.
- **Checkpoint** — structured compact state for settled historical work.
- **Archive** — original canonical messages retained as historical evidence.
- **Recall** — search/read of archived history when exact details matter.

A checkpoint is intentionally not described as lossless. Exact facts should be recovered from the archive.

## v0.1 status

This branch currently contains the provider-neutral core:

- context-budget classification;
- token-size estimation;
- conservative working-set planning;
- structured checkpoint summaries;
- checkpoint rendering;
- in-memory per-session archive;
- lexical history search and paginated read;
- static `SystemPromptContributor` protocol;
- extension manifest scaffold;
- core tests.

The runtime adapter is intentionally not implemented against Posoco 0.9.0 because the current `ModelPort` and `ToolProvider` execution boundaries do not receive the canonical current `RunId` / `SessionId`. Implementing the history tools before that API exists would require model-supplied session IDs or global mutable session state, both of which are rejected by design.

See [`POSOCO_INTEGRATION.md`](POSOCO_INTEGRATION.md) for the small backwards-compatible Posoco API addition required to complete the adapter.

## Intended tools after scoped runtime support lands

- `session_checkpoint` — prepare a structured checkpoint for a host-selected historical candidate.
- `session_history_search` — search only the current session archive.
- `session_history_read` — paginated exact read from one archived entry.
- `session_continuity_status` — report active/archive/checkpoint state.

The model never supplies a session identifier to these tools.

## Safety invariants

1. Current intent stays active.
2. History is archived before it is folded out of the canonical transcript.
3. Checkpoints are working hints; archives are historical evidence.
4. Session identity comes from Posoco, never from the model.

## License

Apache-2.0
