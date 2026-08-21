# posoco-ext-handoff

Deterministic current-work handoff document generation for Posoco.

This extension is **not** a context compactor. It does not summarize the
conversation, inspect another port's private state, transfer ownership, or call
an LLM. Posoco's message tree owns conversation history; `HANDOFF.md` records
the complementary state required to continue the work now.

It writes one project-local artifact:

```text
.handoff/
└── HANDOFF.md
```

## Commands

```text
/handoff create [objective]
/handoff inspect
```

## Minimal composition

The package includes default building blocks, so a product does not need to
implement custom handoff traits just to get started:

```moonbit
let store = DefaultHandoffStore::new()

let workspace = HandoffWorkspaceState::new(
  "/repo",
  branch=Some("feat/handoff"),
  head=Some("abc123"),
  changes=[
    { path: "posoco-ext-handoff/src/handoff.mbt", status: "modified" },
  ],
)

let work = HandoffWorkState::new()
work.set_objective("Implement posoco-ext-handoff")
work.add_done_when("/handoff create writes .handoff/HANDOFF.md")
work.add_constraint("Do not inspect session-private state")
work.set_current_work("Finish default host adapters")
work.set_next_action("Run moon test")
work.validation_not_run("moon test")

let handoff = Handoff::new(
  cwd="/repo",
  store~,
  probe=workspace,
  work_sources=[work],
)
```

`DefaultHandoffStore` is implemented for native and JavaScript targets. It
creates `.handoff/` as needed and replaces `HANDOFF.md` through a sibling
temporary file followed by rename.

`HandoffWorkspaceState` is intentionally host-pushed rather than Git-aware. A
product that already knows branch/HEAD/change facts can update the state
explicitly. The handoff package does not spawn Git or invent a clean workspace
when those facts are unavailable.

## Work state

Products may contribute deterministic work facts through one or more
`HandoffWorkSource` implementations:

```moonbit
pub(open) trait HandoffWorkSource {
  fn handoff_work(Self) -> WorkSnapshot
}
```

`HandoffWorkState` is the included mutable implementation for products that do
not already own structured planner/task state. It supports:

- objective, current work, and one immediate next action
- completion criteria and constraints
- decisions and active blockers
- completed work and queued follow-up work
- notes
- validation states (`passed`, `failed`, `not run`)

State transitions avoid contradictory handoff facts:

- `complete(item)` removes the same item from `queue`
- `resolve_blocker(item)` removes an obsolete blocker
- recording a validation check moves it to exactly one validation bucket
- `snapshot()` returns detached arrays
- `clear()` resets intentionally unrelated work

Multiple work sources are merged in declaration order. Later sources override
singular fields; list fields append unique facts while preserving order.
Explicit `/handoff create` fields are merged last and therefore win.

`HANDOFF.md` itself is never used as an input to the next `create` call.
Repeated creation always snapshots current sources and workspace facts again.

## Workspace seam

Workspace facts are supplied through:

```moonbit
pub(open) trait HandoffWorkspaceProbe {
  fn snapshot(Self, cwd : String) -> Result[WorkspaceSnapshot, String]
}
```

A snapshot contains:

- project root
- optional branch
- optional HEAD
- changed paths with factual status labels

Git is one possible producer of these facts, not part of the handoff protocol.
`HandoffWorkspaceState` is the included explicit-state implementation.

## Persistence seam

Persistence is supplied through:

```moonbit
pub(open) trait HandoffStore {
  async fn exists(Self, path : String) -> Result[Bool, String]
  async fn read(Self, path : String) -> Result[String, String]
  async fn ensure_dir(Self, path : String) -> Result[Unit, String]
  async fn write_atomic(Self, path : String, content : String) -> Result[Unit, String]
}
```

`DefaultHandoffStore` provides the normal project-filesystem implementation on
native (`moonbitlang/async/fs`) and JavaScript (`node:fs`). Products with an
existing filesystem abstraction may inject their own store instead.

## HANDOFF.md contract

Generated documents use this stable section order:

```text
# Handoff
## Objective
## Done When
## Constraints
## Completed
## Current Work
## Decisions
## Blockers
## Workspace
### Changes
## Validation
### Passed
### Failed
### Not Run
## Next Action
## Queue
## Notes
```

`create` refuses to write an incomplete handoff unless these three continuation
anchors are known:

- `Objective`
- `Current Work`
- exactly one `Next Action`

The remaining sections may be empty. `Next Action` is deliberately singular;
subsequent executable work belongs in `Queue`.

Structured command callers may supply:

- `objective`
- `done_when[]`
- `constraints[]`
- `completed[]`
- `current_work`
- `decisions[]`
- `blockers[]`
- `next_action`
- `queue[]`
- `notes[]`
- `validation_passed[]`
- `validation_failed[]`
- `validation_not_run[]`

## Deliberate v1 boundary

The extension does not implement accept/reject/cancel protocol state, session
identity, workspace ownership, conversation export, automatic conversation
summary, or an embedded Git/process runner. Those concerns are outside the
`HANDOFF.md` work-continuation artifact.
