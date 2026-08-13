# posoco-ext-handoff

Deterministic current-work handoff document generation for Posoco.

This extension is **not** a context compactor. It does not summarize the
conversation, inspect another port's session state, transfer ownership, or call
an LLM.

Posoco's message tree owns conversation history. `posoco-ext-handoff` records
the complementary state needed to continue the work now: objective, completion
criteria, constraints, completed work, current work, decisions, blockers,
workspace facts, validation, and one immediate next action.

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

Structured callers may additionally provide:

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

## Work sources

Products may contribute deterministic work facts through one or more
`HandoffWorkSource` implementations:

```moonbit
pub(open) trait HandoffWorkSource {
  fn handoff_work(Self) -> WorkSnapshot
}
```

This is intentionally an extension-local seam, not a Posoco port. A handoff
must not reverse-query another port's private state. If a planner, task manager,
or product workflow already knows useful work facts, the product adapts those
facts explicitly into `HandoffWorkSource`.

Sources are merged in declaration order:

- later sources override singular fields (`objective`, `current_work`,
  `next_action`)
- list fields append unique facts while preserving order
- explicit `/handoff create` fields are merged last and therefore win

`HANDOFF.md` itself is never read as a work source. Re-running `create` takes a
fresh snapshot from configured sources plus the current workspace, so stale
handoff content cannot silently leak into the next handoff.

## HANDOFF.md contract

A generated document uses the stable section order below:

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

`create` refuses to write an incomplete handoff unless all three continuation
anchors are known:

- `Objective`
- `Current Work`
- exactly one `Next Action`

The other sections may be empty. `Next Action` is intentionally singular;
subsequent executable work belongs in `Queue`.

## Host seams

Workspace discovery is supplied through `HandoffWorkspaceProbe`:

```moonbit
pub(open) trait HandoffWorkspaceProbe {
  fn snapshot(Self, cwd : String) -> Result[WorkspaceSnapshot, String]
}
```

It returns:

- project root
- optional branch
- optional HEAD
- changed paths with factual status labels

The extension deliberately does not know how those values are obtained. Git is
one possible implementation, not part of the handoff protocol.

Persistence is supplied through the minimal `HandoffStore` seam:

```moonbit
pub(open) trait HandoffStore {
  async fn exists(Self, path : String) -> Result[Bool, String]
  async fn read(Self, path : String) -> Result[String, String]
  async fn ensure_dir(Self, path : String) -> Result[Unit, String]
  async fn write_atomic(Self, path : String, content : String) -> Result[Unit, String]
}
```

This keeps the package independent of `posoco-ext-workspace` or any specific
filesystem implementation. The host can adapt an existing filesystem service
without making handoff aware of that service's internal architecture.

## Example

```markdown
# Handoff

## Objective

Implement `posoco-ext-handoff` as a standalone Posoco extension.

## Done When

- `/handoff create` writes `.handoff/HANDOFF.md`
- No LLM is required

## Constraints

- Do not inspect session or other port-private state
- Do not modify Posoco core for handoff-specific behavior

## Completed

- Defined the stable handoff document shape

## Current Work

Implementing deterministic work-source composition and Markdown rendering.

## Decisions

- Conversation history remains in Posoco's message tree
- `HANDOFF.md` records continuation state, not conversation history

## Blockers

- `moon` is unavailable in the current development environment

## Workspace

- Root: `/repo`
- Branch: feat/handoff
- HEAD: abc123

### Changes

- `posoco-ext-handoff/src/handoff.mbt` — modified

## Validation

### Passed

- renderer fixture

### Failed

- _(none recorded)_

### Not Run

- `moon test`

## Next Action

Run `moon test`, then fix any MoonBit API mismatches.

## Queue

- Add a concrete host workspace probe adapter

## Notes

- The handoff file is regenerated from current sources on every create
```

## Deliberate v1 boundary

The extension does not implement accept/reject/cancel state, session identity,
workspace ownership, conversation export, or automatic conversation summary.
Those concerns are outside the `HANDOFF.md` work-continuation artifact.
