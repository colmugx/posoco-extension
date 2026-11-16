# PStack port for Posoco

This change adds a Posoco-native harness adaptation for PStack's engineering workflow prompts.

## User-visible result

A Posoco project can discover and activate `poteto-mode` from `.agents/skills`. The skill can load upstream PStack playbooks, leaf skills, principles, and Markdown references progressively through `read_skill_resource`. Project-local subagent presets are provided in `.cetas/agents`.

The port reuses existing extensions. It does not add a parallel tool runtime.

## What's included

- A Posoco `poteto-mode` entry skill with native tool and workflow guidance.
- The upstream PStack Markdown skill, playbook, principle, agent, and guide sources, pinned to commit `bf0c7cd80abdbf7fe47b634978a7d1b4071f71a7`.
- A Posoco harness mapping for delegation, questions, todos, plans, skill activation, model slots, and unsupported Cursor-only services.
- `poteto-agent` and `comment-sicko` kind presets for `posoco-ext-kind` / `posoco-ext-subagent`.
- The upstream MIT license and source provenance.

## Runtime mapping

| Capability | Existing Posoco package |
| --- | --- |
| Skill discovery, activation, resource reads | `posoco-ext-skills` |
| Agent kind presets | `posoco-ext-kind` |
| Child execution, resume, answer/stop | `posoco-ext-subagent` |
| Human and non-blocking questions | `posoco-ext-askquestion` |
| Task list | `posoco-ext-todo` |
| Plan gate and approval | `posoco-ext-plan` |
| Model slot and effort selection | Model Manager control contract |

See [the harness mapping](../.agents/skills/poteto-mode/resources/posoco-harness.md) for exact argument-level semantics and limitations.

## Install and activate

1. Keep `.agents/skills/poteto-mode` in the project. It is discovered by `Skills::discover`.
2. Keep `.cetas/agents/poteto-agent.md` and `.cetas/agents/comment-sicko.md` in the project. They are loaded by `KindCatalog::load`.
3. Compose the existing skills, kind, subagent, ask-question, todo, and plan extensions in the Posoco host. The host must supply the existing `ChildComposer`, UI, task, wakeup, and model-slot configuration required by those packages.
4. Activate the skill with the host's Skills command or the `activate_skill` tool. There is no Cursor-style `/poteto-mode` slash command in this port.

## Deliberate non-goals

This change does not claim parity for Cursor cloud agents, cloud worktrees, Cursor Automations, Bugbot, `/loop`, or the built-in PR tool. Posoco subagent background execution is not cloud isolation. The imported bundle contains Markdown only. Executable helper scripts and their runtimes are not imported. These gaps are explicit in the harness mapping so the skill does not pretend those operations happened.

## Verification

This is a prompt/resource and kind-preset change. No MoonBit package source is changed. Runtime behavior depends on the host composing the listed extensions and capabilities. Validate the Markdown frontmatter and resource paths, then run the repository's normal MoonBit checks in CI.

## Native MoonBit module (follow-up)

`posoco-ext-pstack` turns the above repository-local assets into an installable
MoonBit module. Its `Pstack::discover` factory attaches the bundled
`assets/skills` root to the existing `posoco-ext-skills` runtime. The
`Pstack` Extension contributes that one Skills runtime's tools, catalog
prompt and `skills` command, plus a native `poteto-mode` command. Do not
compose a second independent Skills extension, or its tool names will collide.

The host supplies the resolved installed package's `assets` directory path
and passes the same discovery root when composing child agents. Bundled agent
kinds are exposed with `Pstack::load_kinds`, ready for
`KindCatalog::load(home~, cwd~, extra=specs)`. This preserves per-kind
permission postures and normal project-over-user precedence.

See [the package README](../posoco-ext-pstack/README.mbt.md) for exact
composition, installation and limitation details. This is still a host
integration seam, not a claim that Cursor-only cloud or automation APIs are
implemented. An end-to-end composed Posoco agent test remains required.
