---
name: no-comments
description: Read-only comment review via the comment-sicko subagent kind. Spawn the reviewer on the diff and act on its accepted findings; the kind's own instructions carry the review policy.
disable-model-invocation: true
---

# No comments for Posoco

Spawn the read-only `comment-sicko` reviewer and act on what it accepts. This skill reviews nothing itself and never edits files in its own turn; every finding comes from the kind's own instructions.

## Steps

1. Set the scope: the files or diff the user named, otherwise the current diff against the base branch (default `main`), working tree included.
2. Spawn the reviewer with `subagent(kind="comment-sicko", ...)` and pass it that scope plus the user's framing. Do not restate, summarize, or soften its rules in the spawn prompt: the `comment-sicko` kind's own instructions are the review policy, and duplicating them here only risks drift.
3. Inspect its report. Accept findings inside the scope. Reject application-code edits, scope escapes, and flags that treat kept intentional code as guilty without proof it is about something that cannot change. A constraint keep survives only with that proof.
4. Fix trivial accepted findings directly by deleting a dead path, dropping a parameter, or using the real API. For a fix that needs a new shape, stop at a sketch and implement the smallest root-cause fix in scope. Do not add symptom guards and do not fix instances outside the scope.
5. Constraint comments ("do not remove", "talk to X before changing") get the cheapest in-scope encoding offered as a lint, type, test, or CI check. Wait for the user's approval before encoding; without approval, delete the comment and report the constraint open.
6. Report the deletion count, accepted and rejected findings with reasons, fixes made, encoding offers, and remaining open work.

## Upstream detail

For the fuller upstream procedure, read `read_skill_resource(name="poteto-mode", path="resources/upstream/skills/no-comments/SKILL.md")`. It is upstream Cursor documentation: treat its `Task` tool, `subagent_type` spelling, model-role configuration, `/architect` and `/why` skill commands, and eval pre-approval rules as references, not executable Posoco instructions, and map them onto the Posoco `subagent` tool, kinds, and the host's approval gates. Skip steps with no Posoco equivalent and say so.

## Invocation

The user invokes this Skill explicitly with its `$`-mention in a prompt; Posoco's Skills layer injects these instructions into that turn. The host's permissions gate every fix and encoding decision.
