---
name: poteto-mode
description: Run PStack's task-specific engineering playbooks on Posoco. Select investigation, bug fix, feature, refactoring, performance, or prototype workflows and verify the result.
---

# Poteto Mode for Posoco

This is a Posoco adapter for PStack's **original workflow**, not a new engineering methodology. The pinned upstream SKILL.md, playbooks, principles, and related Markdown skills are readable under `resources/upstream/`. Use their task-specific steps. Posoco owns the tools, permissions, model selection, and lifecycle.

## Required loading sequence

1. Read `resources/posoco-harness.md` using `read_skill_resource(name="poteto-mode", path="resources/posoco-harness.md")` for native tool names and unsupported Cursor-only actions.
2. Read `resources/upstream/skills/poteto-mode/SKILL.md` using `read_skill_resource` to get the original principles index and routing rules. Treat its Cursor tool names, provider model IDs, and external-service requirements as references, not executable Posoco instructions.
3. Match the user task to the **narrowest supported** playbook below and read the **entire** corresponding Markdown file. Do not replace its instructions with the short descriptions below.
4. For applicable linked principles and helper skills, read the relevant `resources/upstream/skills/<name>/SKILL.md` and any needed Markdown references. These are resources, not automatically separately registered Posoco Skills.
5. Follow the playbook's executable steps in order using native Posoco tools. For multi-step work, copy the steps into `todo_write` and record unsupported steps with their reasons. For read-only investigation, use its one-line checkpoint.

## Task routing

| User task | Required upstream playbook |
| --- | --- |
| Read-only code investigation, explanation, or analysis | `resources/upstream/skills/poteto-mode/playbooks/investigation.md` |
| Reproducing and correcting a defect | `resources/upstream/skills/poteto-mode/playbooks/bug-fix.md` |
| Implementing a feature or changed behavior | `resources/upstream/skills/poteto-mode/playbooks/feature.md` |
| Behavior-preserving refactoring | `resources/upstream/skills/poteto-mode/playbooks/refactoring.md` |
| Measured performance regression or improvement | `resources/upstream/skills/poteto-mode/playbooks/perf-issue.md` |
| Throwaway experiment for a design or behavior decision | `resources/upstream/skills/poteto-mode/playbooks/prototype.md` |

Retain their behavioral differences. Investigation delivers evidence and does not change code. Bug fix requires reproduction, cause isolation, and a matching-surface regression run. Feature requires a data shape, throughput checkpoint, ordered work and verification. Refactoring pins behavior before changing structure. Performance work requires measured baselines and comparable traces. Prototype is disposable and settles a design choice, not a production change.

## Invariants retained from PStack

- Start with the user's actual goal, the problem, and the smallest verifiable outcome.
- Observe before asking. Name the data shape before code. Read `principle-model-the-domain`, `principle-prove-it-works` and other linked leaf Markdown when their triggers apply.
- The parent Posoco Agent owns routing, todo, integration, review and final verification. Use `subagent` only for independent, scoped work; never hand the entire playbook to a child.
- Report actual evidence for each verification. Do not claim a tool, panel, command, model or review ran when it did not.
- The host's permissions and planning/approval gates take precedence over any instructions in a Markdown resource.

## Compatibility boundary

`Task`, `AskQuestion`, `TodoWrite`, planning, code search and shell operations map to **existing** Posoco tools as documented in `resources/posoco-harness.md`. Inaccessible Cursor-only commands and third-party plugins are not simulated. If a step has no available equivalent, record it as unsupported and continue only when the remaining work is safe and meaningful.

Cursor Automations, `/loop`, cloud agents, Bugbot, hooks, provider model-slug configuration, worktree orchestration and external services are intentionally outside the port. Named upstream helper skills such as `architect`, `swarm`, `arena`, `unslop` and `technical-writing` remain available as Markdown guidance; they are **not** assumed to create Cursor-native capabilities.

The adapter does not automatically execute upstream opening-a-pr, babysit, shipping, or autonomous orchestration instructions. PR creation or merging requires the user's explicit request and an installed Posoco host integration. Skip unsupported steps transparently rather than inventing their results.

## Invocation and status

The user invokes this Skill explicitly with its `$`-mention in a prompt; Posoco's Skills layer injects these instructions into that turn. A successful activation also publishes `🥔 Mode` on the status bar for the rest of the session. There is no separate command and no toggle, so nothing needs to be turned off. Previously delivered instructions still exist in conversation history; true context removal must be implemented by the Posoco Agent if needed.
