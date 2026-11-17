# PStack workflow to Posoco runtime contract

Read this before executing an upstream PStack playbook. Preserve the original task-specific workflow and substitute only existing Posoco primitives. Do not invent a Cursor emulator.

| PStack/Cursor primitive | Posoco primitive | Execution boundary |
| --- | --- | --- |
| Activate a skill or read a playbook/principle | `activate_skill` and `read_skill_resource(name="poteto-mode", path="resources/upstream/...")` | Leaf Markdown is a resource unless installed separately as a Posoco Skill. |
| `Task`, `subagent_type` | `subagent` with `task`, `kind` and `instructions` | Parent owns workflow; child is depth-one, not a workflow coordinator. |
| `run_in_background`, `resume` | `subagent.background`, `subagent.resume` | Background is default; resume only for costly child-local state. |
| Named provider model/effort | Host-configured `subagent.model` / `subagent.effort` | Omit if unconfigured; Cursor model slugs are not portable. |
| `AskQuestion` | `ask_question` or `notify_user` | Ask product choices, not empirically observable questions. |
| `TodoWrite` | `todo_write`, `todo_read` | Keep the playbook's ordered steps and skipped-step reasons. |
| Plan and approval | `plan`, `enter_plan_mode`, `exit_plan_mode` | Obey Posoco permission and approval gates. |
| Grep, Glob, Bash, editor | Composed Posoco filesystem/search/shell tools | Test on the matching surface when available. |
| Independent code review | Read-only kind or parent review and tests | Do not claim an unavailable reviewer panel ran. |

## Workflow-specific translations

**Investigation:** inspect source and evidence, keep the read-only throughput checkpoint, and return the original structured explanation; do not change code.

**Bug fix:** reproduce the original symptom, eliminate hypotheses using runtime evidence, confirm the root cause, implement the minimal fix and replay the reproduction. A Cursor UI control skill is not required when Posoco's available tools can reproduce it directly.

**Feature:** read the affected subsystem, identify the model/data shape, explore viable designs if needed, record the four-part throughput checkpoint, implement in ordered verified steps and review the diff.

**Refactoring:** pin the old behavior, define the target shape, subtract obsolete code, migrate callers, and prove equivalence.

**Perf issue:** capture baseline measurements, trace actual bottlenecks, test changes and compare like-for-like results with units.

**Prototype:** create a disposable experiment, observe the decision-driving behavior and report the tradeoffs. Do not ship the throwaway as production code.

## Host composition

The installed `posoco-ext-pstack/assets` path must be passed as `assets_root` to `Pstack::discover(fs, cwd~, home~, assets_root~, events~)`. It merges the packaged file-backed workflow into the same Skills runtime as project/user Skills. Do not compose a second duplicate Skills extension. If the assets are unavailable, discovery returns `None` instead of silently using an incomplete built-in substitute.

The host may compose its existing `posoco-ext-subagent`, `posoco-ext-todo`, `posoco-ext-askquestion`, `posoco-ext-plan` and `posoco-ext-kind` extensions. PStack does not instantiate these or grant permissions. If children require playbooks, their Skills composition must also be able to discover the PStack asset root. Optional Kind presets are available through `Pstack::load_kinds`; existing host kinds are also usable.

## Out of scope

Cursor cloud agents, Automations, `/loop`, Bugbot, hooks, plugin-provided commands, worktree orchestration and model-specific settings are not native Posoco features. Upstream steps relying on them must be skipped or translated only when a real configured equivalent exists. Opening a PR or shipping are not automatic side effects of this port.

## Provenance

The upstream Markdown remains pinned to `cursor/plugins` commit `bf0c7cd80abdbf7fe47b634978a7d1b4071f71a7` under `resources/upstream` (MIT).
