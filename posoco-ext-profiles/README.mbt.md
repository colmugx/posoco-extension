# posoco-ext-profiles

[Progressive context intent packages for Posoco agents](https://mooncakes.io/docs/colmugx/posoco-ext-profiles) —
a profile is a named manifest (id, name, description, member ext list) that
bundles related extensions into one working mode. The model activates a
profile with a single `activate_profile` call and the members' prompt manuals
ride the next model request as one append-only user message; tool schemas stay
behind the lazytools gateway the whole time.

> **Targets: all backends** — pure catalog logic, zero IO in-package.

## Ports contributed

| Port | Contribution |
|---|---|
| `ToolProvider` | the `activate_profile` meta tool (model self-activation) (src/meta_tool.mbt) |
| `SystemPromptContributor` | the `## Profiles` menu section: one `id: description` row per manifest plus the `all` fallback sentence (src/prompt_menu.mbt) |
| `PipelineHook` | `before_model`: appends one activation user message per pending activation and fires the bus event (src/hook.mbt) |
| `Observer` | per-session tool usage counters feeding `/profile save`, unwrapping lazytools gateway calls to the inner tool name (src/usage.mbt) |
| `CommandPort` | `/profiles` (manual activation selector) and `/profile save` (skill-creator-shaped save) (src/command.mbt) |
| `Lifecycle` | `on_compose` captures the composed `UiPort` for the selector (src/command.mbt) |

## Activation flow

- **The transcript is the single source of truth.** The extension keeps zero
  in-memory activation state; the activated set is rebuilt by scanning every
  user message's first Text line — on resume, after compact, and before each
  model request, from the same one function (src/header.mbt).
- **The header line is frozen contract, not presentation.** Every activation —
  meta tool or manual — injects exactly one user message whose first Text line
  is `profile <id> activated` (src/header.mbt, src/hook.mbt). Compactors must
  preserve this line; see the v1 boundary below.
- **Pending detection**: an executed `activate_profile` call whose
  `Success` result first line starts with `activated: ` and whose header line
  is not yet in the transcript is pending and gets injected; a first line
  starting with `unknown profile` is an explicit never-inject verdict. The two
  prefixes are produced by this package's meta tool and consumed by its
  scanner — keep both sides in sync (src/header.mbt, src/meta_tool.mbt).
- **Injection coverage = deep-deferred set ∩ profile members.** Deferred
  members get their captured manual text; members outside the deferral are
  already resident and are only listed as `already resident (no
  re-injection): ...`, never re-injected (src/hook.mbt).
- **Idempotence**: a profile already carrying its header line in the
  transcript is never injected again; the hook keeps no memory and is safe to
  re-run before every model request within a run (src/header.mbt,
  src/hook.mbt).
- **Event**: each injection publishes `profiles.activated` with payload
  `{id, members}` on the devkit `EventBus` at the injection point (F4) —
  publishing with no bus or no subscribers is a no-op (src/hook.mbt).

## Meta tool

`activate_profile` takes one required string argument `profile` — the id
exactly as listed in the menu. The result text is contract, not prose
(src/meta_tool.mbt):

- Known id — `Success` whose first line is `activated: <id>`, followed by the
  notice that the manual is injected with the **next model request** and takes
  effect within the current turn, so the model must not end the turn to wait
  for another user message (F7).
- Unknown id — `Success` whose first line is `unknown profile: <id>` followed
  by `available: <every activatable id>`, `all` included (the menu mirror).
  The hook reads the same first line as a never-inject verdict.
- Missing or non-string `profile` — `ToolReportedError` steering text; a
  different tool name raises `RuntimeError::UnknownTool`.

The builtin `all` preset (members = the deep-deferred set) is activated like
any profile — one code path, no special-casing (src/profiles.mbt).

## Save flow

`/profile save` is fully manual (skill-creator shape) and persists the
session's observed usage as a new profile (src/command.mbt):

1. **Usage counting** — the Observer counts successful `ToolCallResult` events
   per session (scope-keyed; unscoped events are skipped) and only for tools
   present in the host's static attribution table. Gateway calls travel as
   `tool_execute` with the real name in the `tool` argument and are unwrapped
   to the inner tool name first (src/usage.mbt).
2. **Naming** — name and description come from the host-injected summarizer
   seam (a synchronous `(ext, count)[] -> (name, description)` function) when
   wired, else a deterministic derivation (`session-<top ext>`,
   `auto-saved from session usage: <top-5 ext:count pairs>`). An explicit
   `name` argument overrides both. The id is minted legal and unique
   (lowercase, `-`-collapsed, `-N` suffix on collisions with the catalog or
   the reserved `all`) (src/command.mbt).
3. **Persistence** — the manifest is written through the `ProfileStore` seam
   (default level `user`, optional `level` argument); a write failure is a
   `Failure` and the manifest stays out of the catalog. With no store wired
   the save is catalog-only — nothing persists. Either way the manifest
   enters the in-memory catalog immediately, so `activate_profile` accepts it
   the same session; the menu and the deep-deferred views stay
   composition-time static and the full benefit lands at the next composition
   (Q19) (src/command.mbt, src/prompt_menu.mbt).

## Composition seam

Host wiring — the whole policy lives at composition time; nothing here
touches a session (src/defer_view.mbt, src/profiles.mbt):

- `deep_defer_extensions(exts~) -> (captured, views)` strips BOTH `tools` and
  `prompt_contributors` from member extensions (lazytools' toolless views
  keep prompt sections; deep deferral must strip them or activation
  double-injects). `captured` maps ext id to the stripped prompt text;
  `views` are the replacements to register — extensions with neither tools
  nor prompt sections pass through unchanged. The deferred set itself is the
  host's Q10 policy (typically the union of loaded profiles' exts; hosts may
  protect never-defer extensions by leaving them out).
- `Profiles::build(manifests~, defer_set~, captured_prompts~, attribution~,
  bus?, store?, session_store?, summarizer?)` — every input is a
  composition-time constant. The host resolves the two-level manifest
  directory before calling (project overrides user on id collisions; the
  reserved `all` and path separators are rejected by
  `parse_profile_manifest`). `defer_set` is also the member list of the
  builtin `all`. `attribution` is the tool-name → ext-id static snapshot.
  Referenced-but-uncomposed ext ids are reported via `Profiles::warnings()`
  and annotated in the menu; activation proceeds without them (src/types.mbt,
  src/profiles.mbt, src/prompt_menu.mbt).
- **Register profiles BEFORE lazytools** (Q17): hook chains run in
  registration order, so the lazytools envelope stays last. Register the
  deep-deferred views instead of the member originals, or their prompts stay
  resident and activation double-injects (src/extends.mbt, src/defer_view.mbt).

```mbt nocheck
// 1. Strip member surfaces (deferred set = the host's policy product).
let (captured, views) = deep_defer_extensions(exts=member_exts)

// 2. Build the extension from composition-time constants.
let profiles = Profiles::build(
  manifests=loaded_manifests,
  defer_set=deferred_ids,       // also the `all` membership
  captured_prompts=captured,
  attribution=tool_catalog,
  bus=Some(devkit_bus),
  store=Some(host_profile_store),
)

// 3. Register before lazytools; swap member originals for views.
let agent = @posoco.Agent(
  exts=[..resident_exts, profiles, lazytools_gateway, ..views],
  config=config,
)
```

## Deliberate v1 boundary

- **Host wiring is not finished.** cetas hosts do not yet (a) pass
  `session_id` in command invoke args, (b) inject a `SessionStore` at build,
  or (c) apply the deep-deferred views. Consequences inside the package:
  `/profiles` selection reaches `manual_activate` and returns an explicit
  `Failure` naming the missing wiring when the store or the `session_id`
  argument is absent; `/profile save` fails explicitly on a missing
  `session_id`, on empty usage, or when a wired `ProfileStore` rejects the
  write — with no store wired it still succeeds, but catalog-only
  (src/command.mbt).
- **Compact contract across packages**: compactors must preserve every
  `profile <id> activated` header line (bodies may compress) — resume rebuild
  scans them (Q14). This is a requirement on the posoco-kit-compact-* kits
  and currently has no owner (src/header.mbt).
- The `/profiles` selector lists catalog manifests only; the builtin `all` is
  reachable through the menu's fallback sentence and the meta tool, not the
  selector (src/command.mbt, src/prompt_menu.mbt).
- The menu section is byte-stable per composition (prompt-cache prefix);
  runtime-saved profiles appear in it only at the next composition
  (src/prompt_menu.mbt).
