# posoco-ext-pstack

A native, installable Posoco Extension that ports the core engineering method of [PStack](https://github.com/cursor/plugins/tree/main/pstack).

PStack supplies the method; Posoco supplies the Agent runtime. The primary \`poteto-mode\` Skill is a true inline \`SkillDescriptor::builtin\`, compiled into this package. Activating it does not depend on finding an installed \`assets/\` directory.

## Install

\`\`\`sh
moon add colmugx/posoco-ext-pstack
\`\`\`

## Compose

The host supplies its workspace filesystem and an owner-bound event publisher. Compose the normal StatusBar on the same EventSystem:

\`\`\`moonbit
let events = @posoco.EventSystem()
let statusbar = @statusbar.StatusBar(events=Some(events))
let pstack_events = events.publisher(owner="posoco_ext_pstack").unwrap()
let pstack = @pstack.Pstack::builtin(fs, events=Some(pstack_events)).unwrap()
let agent = @posoco.Agent(exts=[pstack, statusbar, ..other_extensions], events~, config~)
\`\`\`

Alternatively, \`Pstack::discover(fs, cwd~, home~, events~)\` discovers project/user Skills and merges the built-in method into the same catalog. A same-name project/user Skill intentionally overrides the built-in. Do not also compose a standalone Skills extension: PStack already owns the Skills tools and prompt contributor.

## Native behavior

- **Built-in Skill:** \`poteto-mode\` is registered with \`SkillDescriptor::builtin\`; activation works without package assets on disk.
- **Slash command:** \`/poteto-mode\` activates the Skill through the normal Skills activation path.
- **Status bar:** successful activation publishes a segment with key \`🥔\`, value \`Mode On\`, and semantic color \`success\`. With \`posoco-ext-statusbar\` composed on the same EventSystem, it renders as **🥔 Mode On**.
- **Deactivation:** \`/poteto-mode-off\` clears the segment.
- **Lifecycle:** Agent shutdown clears an active segment. Repeated activation/deactivation is idempotent.
- **Skills tools:** reuses \`activate_skill\`, \`read_skill_resource\`, and \`skill_search\` from \`posoco-ext-skills\`.

Without an event publisher, Skill activation still works but the status segment cannot be published. Status rendering also requires the host to compose \`posoco-ext-statusbar\` with the same EventSystem.

## Core method

The built-in Skill captures the essential PStack engineering method: goal-first framing; evidence before questions; domain modeling and tracing before implementation; narrow workflows for investigation, bug fixes, features, refactors, and reviews; deliberate delegation; small verifiable units; root-cause fixes; behavioral verification; independent diff review; and honest reporting.

The package does not emulate Cursor or Claude Code runtimes. It does not claim compatibility with Cursor Automations, Slack, Bugbot, cloud agents, Cursor-specific commands, hooks, or model slugs.

## Upstream and license

The imported upstream Markdown reference bundle is pinned to Cursor Plugins commit \`bf0c7cd80abdbf7fe47b634978a7d1b4071f71a7\`. The original PStack MIT license and upstream README remain under \`assets/skills/poteto-mode/resources/upstream/\`; provenance is documented in \`resources/UPSTREAM.md\`. The built-in Skill body is the Posoco-oriented core-method adaptation. The MoonBit adapter is Apache-2.0; imported upstream material remains MIT-licensed.

## Optional Kind presets

The package still includes \`poteto-agent\` and \`comment-sicko\` Kind preset Markdown files. Hosts may call \`Pstack::load_kinds(fs, assets_root)\` and pass the returned specs to \`KindCatalog::load(..., extra=specs)\`. These optional roles are separate from the built-in \`poteto-mode\` Skill.
