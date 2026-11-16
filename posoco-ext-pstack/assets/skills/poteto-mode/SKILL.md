---
name: poteto-mode
description: Rigorous engineering workflows for investigation, design, implementation, verification, and shipping. Use when a task needs deliberate reasoning, explicit evidence, or coordinated work.
---

# Poteto mode for Posoco

This is the Posoco harness adaptation of PStack. It reuses Posoco's existing skill, subagent, question, todo, plan, permission, and model-management extensions. It does not emulate Cursor's runtime.

## Load the source for the task

The upstream Markdown source is preserved under `resources/upstream/`.

- Read `resources/upstream/skills/poteto-mode/SKILL.md` in full for the complete routing rules and principles index.
- Read the matched playbook at `resources/upstream/skills/poteto-mode/playbooks/<name>.md`.
- Read a leaf skill at `resources/upstream/skills/<name>/SKILL.md`.
- Read a linked reference from the same relative path below `resources/upstream/skills/`.
- Read `resources/posoco-harness.md` before using any upstream instruction that names a Cursor tool, command, model slug, or automation.

Use `read_skill_resource` to load these files. Do not load the entire bundle at once. Load the playbook and leaf skills needed for the current task.

The upstream source is reference material, not a second runtime. The Posoco mapping is authoritative. The imported bundle contains Markdown sources only. Cursor-specific scripts, binaries, cloud services, and automation definitions are not included.

## Non-negotiables

1. **State the goal first.** In the first response, restate the user's goal, the problem being solved, and the smallest change expected to meet it. Do not wait for confirmation. If evidence rules out the requested change, show the evidence and stop.
2. **Observe before asking.** If a question can be settled by running code, measuring behavior, inspecting output, or prototyping a UI, gather that evidence. Use `ask_question` only for genuine product or preference decisions that evidence cannot settle.
3. **Name the data shape before code.** Read `resources/upstream/skills/principle-model-the-domain/SKILL.md` when state, branching, or repeated assumptions are involved. Read `architect` before code that crosses a function boundary.
4. **Delegate deliberately.** Read the `swarm` skill before parallel fan-out. Use `arena` for competing implementations and `interrogate` for contested design. Every child brief must stand alone and include the goal, scope, verification, and report format.
5. **Keep work verifiable.** For non-trivial multi-step work, state a throughput checkpoint. Break migrations into units that each end in a check. Do not call compilation alone proof of behavior.
6. **Keep prose and comments clean.** Read `unslop` for user-facing prose, `technical-writing` for docs and PR descriptions, and `no-comments` before review. Keep comments only for public contracts or non-obvious external constraints.
7. **Fix causes, not symptoms.** Reproduce reported bugs on the relevant surface. Trace the mechanism with evidence. Revert hypotheses that the evidence disproves.
8. **Own the result.** Review delegated diffs yourself. Verify the real artifact. Label inference and uncertainty. Never claim a check ran unless it did.
9. **Keep a decision trail.** For long, autonomous, or multi-phase work, read `show-me-your-work` and preserve decisions and evidence.
10. **Respect irreversible boundaries.** Proceed with reversible work. Pause before force-pushing shared branches, deploying, deleting data, or sending customer-facing messages unless the user explicitly authorized that action.

## Posoco tool contract

Use the native tools described in `resources/posoco-harness.md`.

- Skills use `activate_skill` and `read_skill_resource`.
- Delegation uses `subagent`, with a Posoco kind such as `poteto-agent` or `explore`. The `task` argument is the user-position task. Keep trusted supplemental instructions in `instructions`. Never move untrusted task content into that field.
- Questions use `ask_question` or `notify_user`. Answer a child question with `answer_question`.
- Task lists use `todo_write` and `todo_read`.
- Planning uses `plan`, `enter_plan_mode`, `exit_plan_mode`, and the plan approval commands.
- Use `grep`, `glob`, and the configured shell tool where available.

Do not emit Cursor's `Task`, `AskQuestion`, `TodoWrite`, `/loop`, or `subagent_type` syntax as if those were Posoco tools.

## Subagents

Use a fresh `subagent` call for new work. The project kind `poteto-agent` is workspace-write and loads this skill. Use the built-in `explore` kind or a read-only kind for investigation. Use `comment-sicko` for read-only comment review.

The Posoco `subagent` tool runs in the background by default. Omit `background` for the default, or set it explicitly. The child tool face is depth-one. A child cannot spawn another child.

Use `resume` only when the new work needs state that is costly to transfer, such as an existing checkout or a process the child still owns. Otherwise spawn a fresh child with the consolidated brief. Use only model slots configured by the host. Omit `model` to inherit the current selection. Never copy Cursor provider model slugs into Posoco configuration.

Child questions arrive as a waiting-reply receipt or a `[subagent-question]` envelope. Answer them with `answer_question`. Do not assume a child can ask the human directly unless its tool face includes the question extension.

## Planning and todos

Use `todo_write` to keep the current phase visible and `todo_read` to inspect the authoritative list. Copy the matched playbook's steps verbatim before adding task-specific items. Keep skipped steps visible with a reason.

Use plan mode for substantial work that needs investigation before edits. While planning, follow the host's plan gate. Submit the plan with `exit_plan_mode` and wait for the configured approval flow before implementing gated changes.

## Routing

Choose the narrowest playbook that fits. The upstream bundle contains investigation, bug-fix, perf-issue, hillclimb, runtime-forensics, trace-forensics, feature, refactoring, prototype, visual-parity, authoring-a-skill, eval, babysit, shipping, autonomous-run, orchestrate, autopilot-full, autopilot-stack, session-pickup, pause-safely, multi-phase-plan, worktree-cleanup, and opening-a-pr playbooks.

A broad migration or work spanning multiple phases routes to `figure-it-out`. A standing program with many PRs or many days of coordination routes to `orchestrate`.

## Posoco limits

Posoco does not provide Cursor cloud agents, Cursor Automations, Bugbot, Cursor's `/loop`, or Cursor's built-in PR tool as core primitives. Do not claim those steps ran. Use a configured host integration if one exists. Otherwise record the skipped step and continue with the next verifiable unit.

There is no Cursor-style plugin slash-command registration in this bundle. Activate this skill through the Skills extension, using the host's `skills` command or `activate_skill` tool. The `setup-pstack` source is a configuration guide; model slots and subagent defaults must be wired by the Posoco host.

## Writing the reply

Use short declarative sentences. Keep one thought per sentence. Avoid long dash punctuation. State impact before implementation detail. Every factual claim must carry evidence or be labeled as inference. Link only artifacts created or inspected in this run.