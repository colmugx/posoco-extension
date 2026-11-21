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

On the first `$poteto-mode` mention of a session, the native Skills activation returns the file-backed `poteto-mode` instructions to the Agent. Those instructions tell the Agent to read the Posoco harness mapping, upstream root Skill, and matching original playbook before acting, using `read_skill_resource`.

Supported workflow routes: Investigation, Bug fix, Feature, Refactoring, Perf issue and Prototype. The original playbooks are under `assets/skills/poteto-mode/resources/upstream/skills/poteto-mode/playbooks/`. Linked principles and helper Markdown are loaded on demand, not rewritten as a generic prompt.

A successful activation publishes the `🥔 Mode` status segment for the rest of the session. There is no toggle command: the segment mirrors the activation fact and is released when the Agent shuts down. The host must compose `posoco-ext-statusbar` on the same EventSystem (or register that system as the process default) for the display; without a channel the publication is a silent no-op.

Posoco's composed `subagent`, `todo_write`, `ask_question`, planning, search, filesystem and shell tools replace corresponding Cursor primitives only where available. Unsupported Cursor Automations, cloud agents, `/loop`, Bugbot, plugin commands/hooks, provider model slugs, worktree orchestration and external services are not implemented. PR creation, babysitting, shipping and orchestration are not automatic.

## Embedded bundle for zero-config hosts

Hosts that ship PStack inside their binary can skip the assets directory entirely: `Pstack::embedded_descriptors()` returns every registered PStack skill as builtin descriptors with inline instructions and resources. Pass the array to `merge_builtin_skills` instead of composing `Pstack::discover`. The array holds the three hand-written adapters — `poteto-mode`, `poteto-help` (a help-not-work router that answers questions and hands back a prompt), and `no-comments` (spawns the read-only `comment-sicko` reviewer) — plus one generated wrapper per remaining upstream skill: 57 registered skills out of 58 upstream directories.

Generated wrappers live on disk at `assets/skills/<name>/SKILL.md`, so file-backed discovery registers them too, and only route to the pinned upstream instructions: their frontmatter copies the upstream `name`, `description`, and `disable-model-invocation` flag verbatim, and their body points at `read_skill_resource(name="poteto-mode", path="resources/upstream/skills/<name>/SKILL.md")`, at the Posoco primitive mapping in poteto-mode's `resources/posoco-harness.md`, and at the standing rule that unsupported upstream steps are recorded and skipped, never simulated. `scripts/embed-skill-assets.mjs` writes a wrapper only when the file is absent — an existing file is never overwritten, so hand-written content survives regeneration. Which upstream skills are hand adapters and which are deliberately left out is decided in one place, `scripts/bundle-config.mjs`; `make-bot-ui` is excluded because it is pure Cursor Automations/plugin UI machinery (webhook routines, secret-request cards, the chat-header Routines panel) with no portable workflow prose.

`disable-model-invocation: true` (upstream policy; every upstream skill except `setup-pstack` carries it) maps to the descriptor's `user_invoked_only` flag through the generated `embedded_skill_user_invoked_only()` bundle accessor: such skills stay out of the model-facing startup catalog and activate only through explicit user invocation, while remaining fully activatable. The three hand adapters align with their flagged upstream copies; `setup-pstack` stays model-invocable.

`src/embedded_bundle.generated.mbt` is generated from `assets/skills` and `assets/agents`; never edit it. After changing an asset, run `node posoco-ext-pstack/scripts/embed-skill-assets.mjs` and commit its output — `check-assets.mjs` fails when the committed bundle is stale, the generator is not idempotent, an upstream skill has no adapter/wrapper/exclusion, a wrapper carries a `$` literal, or a bundle flag disagrees with its SKILL.md frontmatter.

## Optional Kind presets

The bundle includes `poteto-agent` and `comment-sicko` Markdown presets. Use `Pstack::load_kinds(fs, assets_root)` and pass the entries into `KindCatalog::load(..., extra=specs)` where needed. Zero-config hosts read the same presets from the embedded bundle with `Pstack::embedded_kinds()`, which parses in a deterministic order and names the offending kind on failure. A child must independently discover the same Skill resources if it needs the original workflow; Kind presets alone do not propagate them.

## Verification

```sh
node posoco-ext-pstack/scripts/check-assets.mjs
moon check --target native posoco-ext-pstack/src
moon check --target js posoco-ext-pstack/src
moon test --target native posoco-ext-pstack/src
moon test --target js posoco-ext-pstack/src
```

Package tests cover file-backed discovery, missing-file rejection, native resource loading, the activation-to-status lifecycle, and the embedded descriptor and Kind surfaces. A real host Agent smoke test still depends on its separately composed tools.

## Upstream and license

The source Markdown is pinned to `cursor/plugins` commit `bf0c7cd80abdbf7fe47b634978a7d1b4071f71a7`; imported material and license remain under `resources/upstream/` (MIT). The MoonBit adapter is Apache-2.0.
