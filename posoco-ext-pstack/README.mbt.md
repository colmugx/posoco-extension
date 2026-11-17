# posoco-ext-pstack

PStack's original engineering workflow adapted to Posoco. The module uses PStack's bundled Markdown playbooks, principles and helper skills, while the Posoco Agent supplies the existing tools, model selection, permissions and lifecycle. No Cursor runtime emulator is added.

## Install and compose

```sh
moon add colmugx/posoco-ext-pstack
```

Resolve the installed module's `assets` directory and pass it explicitly. An inline built-in Skill cannot read the original playbooks with `read_skill_resource`, so the main workflow is file-backed.

```moonbit
let events = @posoco.EventSystem()
let statusbar = @statusbar.StatusBar(events=Some(events))
let publisher = events.publisher(owner="posoco_ext_pstack").unwrap()
let pstack = @pstack.Pstack::discover(
  fs, cwd~, home~, assets_root~, events=Some(publisher),
).unwrap()
let agent = @posoco.Agent(exts=[pstack, statusbar, ..other_extensions], events~, config~)
```

`Pstack::discover` returns `None` when the required bundle files are missing or Skills configuration/discovery fails. Report that error instead of silently activating a partial workflow. Project/user Skills retain normal precedence. Do **not** also compose a standalone Skills extension: PStack owns one Skills catalog, command and tool provider.

## Workflow execution

On first `/poteto-mode`, the native Skills activation returns the file-backed `poteto-mode` instructions to the Agent. Those instructions tell the Agent to read the Posoco harness mapping, upstream root Skill, and matching original playbook before acting, using `read_skill_resource`.

Supported workflow routes: Investigation, Bug fix, Feature, Refactoring, Perf issue and Prototype. The original playbooks are under `assets/skills/poteto-mode/resources/upstream/skills/poteto-mode/playbooks/`. Linked principles and helper Markdown are loaded on demand, not rewritten as a generic prompt.

The second `/poteto-mode` toggles off the session status, unregistering the `🥔 Mode On` status segment. Agent shutdown also unregisters it. The host must compose `posoco-ext-statusbar` on the same EventSystem for the display. Turning off cannot retract instructions already included in conversation history.

Posoco's composed `subagent`, `todo_write`, `ask_question`, planning, search, filesystem and shell tools replace corresponding Cursor primitives only where available. Unsupported Cursor Automations, cloud agents, `/loop`, Bugbot, plugin commands/hooks, provider model slugs, worktree orchestration and external services are not implemented. PR creation, babysitting, shipping and orchestration are not automatic.

## Optional Kind presets

The bundle includes `poteto-agent` and `comment-sicko` Markdown presets. Use `Pstack::load_kinds(fs, assets_root)` and pass the entries into `KindCatalog::load(..., extra=specs)` where needed. A child must independently discover the same Skill resources if it needs the original workflow; Kind presets alone do not propagate them.

## Verification

```sh
node posoco-ext-pstack/scripts/check-assets.mjs
moon check --target native posoco-ext-pstack/src
moon check --target js posoco-ext-pstack/src
moon test --target native posoco-ext-pstack/src
moon test --target js posoco-ext-pstack/src
```

Package tests cover file-backed discovery, missing-file rejection, native resource loading, and the toggle lifecycle. A real host Agent smoke test still depends on its separately composed tools.

## Upstream and license

The source Markdown is pinned to `cursor/plugins` commit `bf0c7cd80abdbf7fe47b634978a7d1b4071f71a7`; imported material and license remain under `resources/upstream/` (MIT). The MoonBit adapter is Apache-2.0.
