# posoco-ext-pstack

A native, installable [Posoco](https://github.com/colmugx/posoco)
Extension adapter for [PStack](https://github.com/cursor/plugins/tree/main/pstack).

PStack defines skills, principles, playbooks and agent roles. Posoco owns the
runtime. This module **does not add a second agent loop or orchestration
runtime**. It wraps the existing `posoco-ext-skills` implementation and exposes
the native `/poteto-mode` CommandPort entry, with bundled Markdown resources
and typed Kind presets for the host to load.

## Install

```sh
moon add colmugx/posoco-ext-pstack
```

The module archives its Markdown assets under `assets/`. The host must resolve
the installed module directory and pass the absolute path to its `assets`
directory. The adapter does **not** guess a current working directory or
reach through package-private module paths.

## Host composition

```moonbit
// moon.pkg imports posoco-ext-pstack @pstack, plus other extensions.
// fs is a &@workspace.WorkspaceFs supplied by the host.
// assets_root is the actual installed .../posoco-ext-pstack/assets directory.

let pstack = @pstack.Pstack::discover(
  fs, cwd~, home~, assets_root~,
)
let specs = @pstack.Pstack::load_kinds(fs, assets_root)
// The host passes specs to @kind.KindCatalog::load(home~, cwd~, extra=specs)
// and the resulting KindCatalog to @subagent.SubagentTools.
//
// Compose the returned Pstack extension and normal Posoco extensions.
// Do NOT also compose a separate Skills extension: Pstack owns its Skills
// runtime and contributes activate_skill, read_skill_resource, skill_search,
// the 'skills' command, and the 'poteto-mode' command as one Extension.
```

`Pstack::discover` returns `None` if the bundle root is missing, no
`poteto-mode` skill is found, or Skills configuration is invalid.
`Pstack::load_kinds` returns an error if an agent file is missing or invalid.
A host should report these failures instead of silently running without the
required features.

## Native tool and command mapping

| PStack requirement | Posoco mechanism |
| --- | --- |
| Invoke the workflow | `poteto-mode` CommandPort, or `activate_skill("poteto-mode")` |
| Load a playbook or reference | `read_skill_resource(name="poteto-mode", path="resources/upstream/...")` |
| Delegate or resume work | `posoco-ext-subagent` (ChildComposer + KindCatalog) |
| Ask the user | `posoco-ext-askquestion` (UiPort) |
| Track work | `posoco-ext-todo` |
| Request plan approval | `posoco-ext-plan` |
| Model routing | Host ModelManager/selected subagent slots |
| Permission policy | Posoco permission extension and host tool governance |

The command returns the exact same structured
`agent_skill_activation` result as `skills activate poteto-mode`. The
product host is responsible for delivering that instruction payload to the
Agent's next turn, as it is for normal Skills command activations.

The parent's discovered skill root must also be supplied to subagent child
compositions. Loading Kind presets alone does not automatically enable
resources in the child context. The host must include the same bundle root
when constructing child Skills instances.

## Precedence and trust

`Pstack::discover` appends bundled skills as an extra discovery root, after
project and user roots. Project/user skill overrides therefore have the
existing Posoco precedence. `Pstack::load_kinds` returns `KindSpec` values
for use as `KindCatalog::load(..., extra=specs)`; project and user Kind files
still override them. No Skill metadata grants permission.

The bundle includes the original PStack MIT-licensed Markdown sources pinned
to upstream commit `bf0c7cd80abdbf7fe47b634978a7d1b4071f71a7`.
See `assets/skills/poteto-mode/resources/upstream/LICENSE` and
`assets/skills/poteto-mode/resources/UPSTREAM.md`.
The Posoco-specific MoonBit adapter uses Apache-2.0.

## Limits

This package does not implement Cursor cloud agents, Worktree isolation,
Automations, Bugbot, the Cursor `/loop` command, or Cursor's built-in PR
tool. Upstream executable scripts were not imported. Such steps require
independently configured Posoco host integrations.

## Verification

The package is a native `Extension` with `CommandPort`, reusing
`posoco-ext-skills` ToolProvider and SystemPromptContributor. Its pure
discovery-options and command definitions are tested by `moon test`.

The resource bundle is checked by
`node posoco-ext-pstack/scripts/check-assets.mjs`. Running a real Feature
playbook with a composed host remains a separate end-to-end requirement.
