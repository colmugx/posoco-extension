# posoco-ext-handoff

Deterministic current-work handoff document generation for Posoco.

This extension is **not** a context compactor. It does not summarize the
conversation, inspect another port's session state, transfer ownership, or call
an LLM.

Posoco's message tree owns conversation history. `posoco-ext-handoff` records
the complementary state needed to continue the work now: objective, completion
criteria, current work, workspace facts, validation, and one immediate next
action.

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
- `completed[]`
- `current_work`
- `next_action`
- `queue[]`
- `notes[]`
- `validation_passed[]`
- `validation_failed[]`
- `validation_not_run[]`

The extension also accepts a deterministic `collect_work` callback. Explicit
command fields overlay the collected work state; arrays are merged without
duplicates.

## HANDOFF.md contract

A generated document uses the stable section order below:

```text
# Handoff
## Objective
## Done When
## Completed
## Current Work
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

`Done When`, `Completed`, `Queue`, `Notes`, and validation lists may be empty.

## Workspace seam

The host provides a `HandoffWorkspaceProbe` implementation returning:

- project root
- optional branch
- optional HEAD
- changed paths with factual status labels

The extension deliberately does not know how those values are obtained. Git is
one possible implementation, not part of the handoff protocol.

## Example

```markdown
# Handoff

## Objective

Implement `posoco-ext-handoff` as a standalone Posoco extension.

## Done When

- `/handoff create` writes `.handoff/HANDOFF.md`
- No LLM is required

## Completed

- Defined the stable handoff document shape

## Current Work

Implementing deterministic Markdown rendering.

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

- Add host workspace probe integration

## Notes

- Conversation history remains in Posoco's message tree
```

## Deliberate v1 boundary

The extension does not implement accept/reject/cancel state, session identity,
workspace ownership, or conversation export. Those concerns are outside the
`HANDOFF.md` work-continuation artifact.
