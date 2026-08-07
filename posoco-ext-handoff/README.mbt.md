# posoco-ext-handoff

Deterministic current-work checkpoint and ownership transfer for Posoco.

This extension is **not** a context compactor and does **not** call an LLM.
It writes the current project handoff to:

```text
.handoff/
├── state.json   # authoritative machine protocol state
└── HANDOFF.md   # deterministic human/agent-readable view
```

## Commands

```text
/handoff create [objective]
/handoff inspect
/handoff accept
/handoff reject [reason]
/handoff cancel
/handoff status
```

Structured callers may additionally supply `objective`, `current_step`,
`next_action`, `completed`, `pending`, `validation_passed`,
`validation_failed`, and `validation_not_run` fields in the command JSON.
Missing semantic fields remain unspecified; the extension never invents them.

## State machine

```text
create                 accept
  ───────► offered ─────────────► active
               │                    │
               ├── reject           └── create (next generation)
               ▼
            rejected
               │
               └── create (next generation)

source cancel
     offered ─────────► cancelled ──► create (next generation)
```

`accept` re-probes the workspace and refuses the transfer when the current
workspace signature differs from the signature captured by `create`.

An `active` handoff may only be handed off again by its target/owner session.
An `offered` handoff must be accepted, rejected, or cancelled before another
handoff can be created.

## Host integration

The host provides two deterministic inputs:

- `HandoffWorkspaceProbe`: captures project root, Git HEAD/branch, changed
  files, and a stable workspace signature. The signature **must exclude
  `.handoff/` itself**.
- `collect_work`: returns structured work facts already known by the host.

Ownership-changing commands require Posoco's `CommandInvocationContext` so the
extension receives the current `session_id` explicitly. Existing commands stay
compatible through the default `CommandPort::invoke_with_context` fallback.

## Cetas v1

The Cetas adapter uses fixed-argv Git commands through Bun (no user-provided
shell command) and chooses the Git top-level directory as the handoff root.
Plan-mode state is contributed deterministically when available.

## Deliberate v1 limits

- Cross-process `accept` is not yet protected by a compare-and-swap/file lock.
  Cetas serializes commands within one application process, but two independent
  processes could race.
- The protocol says an offered source has relinquished work, but v1 does not
  yet hard-block subsequent model/tool turns from that source session.
- `.handoff/` is excluded from the Cetas workspace signature, but v1 does not
  automatically edit `.git/info/exclude`.
- The Cetas adapter currently requires a Git worktree for reliable stale-state
  verification.

These are protocol/runtime hardening tasks, not reasons to add an LLM.
