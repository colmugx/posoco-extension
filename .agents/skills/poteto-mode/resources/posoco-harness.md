# Posoco harness mapping

This document is the runtime contract for the imported PStack Markdown. When an upstream file names a Cursor primitive, translate it using this table. Do not infer that a similarly named feature has identical semantics.

## Primitive mapping

| PStack / Cursor concept | Posoco primitive | Contract and limits |
| --- | --- | --- |
| Activate a skill or invoke `/name` | `activate_skill`; `read_skill_resource`; `skills` command | Skill activation loads instructions. Resource reads are relative to the activated skill root. There is no automatic Cursor slash-command registry. |
| `Task` | `subagent` | Pass the task in `task`. Select a preset with `kind`. Use `instructions` only for trusted supplemental instructions. |
| `subagent_type: poteto-agent` | `kind: poteto-agent` | Project kind is defined in `.cetas/agents/poteto-agent.md`. It uses workspace-write mode and loads `poteto-mode`. |
| `subagent_type: comment-sicko` | `kind: comment-sicko` | Project kind is read-only and reports comment deletions and refactor targets. |
| `subagent_type: generalPurpose` | Choose a Posoco kind | Use `explore` for read-only investigation, `coder` for implementation, or a project kind. These are presets, not a generic Task API. |
| `readonly: true` | Kind `mode: readonly` | Permission posture is declared by the kind. Do not emulate read-only by merely asking a writable child not to edit. |
| `readonly: false` | Kind `mode: workspace_write` or `interactive` | Choose the permission posture deliberately. The host permission layer remains authoritative. |
| `run_in_background: true` | `subagent.background` | Background is already the default. Omit the argument or pass `true`. |
| `resume` | `subagent.resume` | Pass the child session id. Resume only when the child owns state that is expensive to transfer. |
| `model` / `effort` | `subagent.model` / `subagent.effort`; `SubagentConfig`; model manager | Values must be configured Posoco model-slot ids and advertised effort levels. Omit to inherit. Upstream provider slugs are not portable. |
| `tools` whitelist | `KindSpec.tools` or `subagent.tools` | The tool face is intersected with the kind whitelist. It does not grant permission. |
| Skill allow-list | `KindSpec.skills` or `subagent.skills` | Pass skill names. `true` loads all discovered skills; `false` or omission loads none. |
| Context files | `subagent.context_files` | Explicitly opt into inherited project context files. |
| `AskQuestion` | `ask_question` | Blocking human input through the composed `UiPort`. |
| Non-blocking question | `notify_user` | Submits a question without blocking the current turn. The host must render and route the answer. |
| Answer a child question | `answer_question` | Use the question id and the matching text, confirm, or option-index field. |
| Open/update a todolist | `todo_write`; inspect with `todo_read` | Full replacement writes. Use statuses `pending`, `in_progress`, and `completed`. |
| Plan mode | `plan`, `enter_plan_mode`, `exit_plan_mode`, `plan.approve`, `plan.reject`, `plan.dismiss` | The host's `PlanMode` gate controls writes until approval. |
| `Grep`, `Glob` | `grep`, `glob` | Use the installed Posoco tools. |
| `Bash` | Host-configured shell tool, commonly `bash` | Tool names are host-configured. Respect the permission layer and plan-mode shell gate. |
| Cursor `/setup-pstack` | Host configuration | Configure `SubagentConfig`, `KindSpec`, and model slots in the Posoco host. No setup command is registered here. |
| Cursor cloud agent / cloud worktree | No core equivalent | Posoco subagents are embedded child agents. Background execution is not cloud isolation or a separate worktree. |
| Cursor `/loop` and Automations | No core equivalent | Use a separately configured scheduler or automation integration. Otherwise run a bounded manual loop and report the limit. |
| Bugbot | No core equivalent | Use configured review tooling. Do not claim Bugbot ran. |
| Cursor built-in PR tool | Host GitHub integration or configured CLI | Use the connected forge integration when available. Otherwise report that PR creation is unavailable. |

## Composition requirements

The bundle is data and prompt content. It relies on existing Posoco packages and host composition.

- `posoco-ext-skills` discovers this skill from the project `.agents/skills` root. The host must compose `Skills::discover(fs, cwd~, home~)`.
- `posoco-ext-kind` loads project agent presets from `.cetas/agents`. The host must load `KindCatalog::load(home~, cwd~)` and pass it to `SubagentTools`.
- `posoco-ext-subagent` requires the host's `ChildComposer`, `SubagentConfig`, and composed task/wakeup capabilities. It provides `subagent`, `answer_question`, and `stop_subagent`.
- `posoco-ext-askquestion` requires a composed `UiPort` for human-facing questions.
- `posoco-ext-todo` consumes the composed UI and provides `todo_write` / `todo_read`.
- `posoco-ext-plan` provides the plan gate and approval flow. The host must wire its permission and review surfaces as appropriate.

The bundle does not change MoonBit package code or create host composition automatically. A host that omits one of these extensions will not have that primitive. In particular, the presence of a skill file does not grant tools or permissions.

## Agent preset semantics

`.cetas/agents/poteto-agent.md` and `.cetas/agents/comment-sicko.md` are loaded by `KindCatalog::load`. Their `mode` fields select the permission posture. The `skills` field is a loading allow-list. The `tools` field, when present, is a tool-face whitelist and is not an authorization grant.

The parent agent owns the plan, todo list, child lifecycle, and final review. A child never spawns another child because the Posoco subagent tool is structurally depth-one.

## Source import boundary

This port vendors upstream Markdown under `resources/upstream`, preserving the original relative directory layout. It includes the skill definitions, playbooks, principles, Markdown references, agent prompts, and guide pages. It does not import TypeScript, shell, Java, TLA+, model-specific configuration, Cursor plugin metadata, or Cursor automation assets. Where an upstream Markdown file references an omitted executable asset, treat that step as unavailable until a Posoco-native replacement is added.

Upstream snapshot: `cursor/plugins` commit `bf0c7cd80abdbf7fe47b634978a7d1b4071f71a7`. License: MIT. See `resources/upstream/LICENSE`.